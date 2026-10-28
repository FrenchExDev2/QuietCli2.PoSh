#requires -Version 7.6
BeforeAll {
    $script:ReleaseRoot = Split-Path -Parent $PSScriptRoot
    $script:ReleaseCheck = Join-Path $ReleaseRoot 'scripts/Test-QuietCliRelease.ps1'
    $script:ArchiveBuilder = Join-Path $ReleaseRoot 'scripts/New-QuietCliArchive.ps1'
    $script:PackageBuilder = Join-Path $ReleaseRoot 'scripts/New-QuietCliPackage.ps1'
    $script:Publisher = Join-Path $ReleaseRoot 'scripts/Publish-QuietCliPackage.ps1'
    Import-Module (Join-Path $ReleaseRoot 'FrenchExDev.QuietCli.PoSh.psd1') -DisableNameChecking
    Import-Module Microsoft.PowerShell.PSResourceGet -RequiredVersion 1.2.0
    function ReleaseFixture {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        foreach ($folder in @('src','examples','fixtures','skills','test','scripts','verification','doc','resources','third_party')) {
            [void][IO.Directory]::CreateDirectory((Join-Path $path $folder))
        }
        foreach ($name in @('FrenchExDev.QuietCli.PoSh.psm1','src/QuietCli.psm1','README.md','LICENSE','THIRD-PARTY-NOTICES.md')) {
            [IO.File]::WriteAllText((Join-Path $path $name), '# release fixture')
        }
        foreach ($name in @('FrenchExDev.QuietCli.PoSh','src/QuietCli')) {
            New-ModuleManifest -Path (Join-Path $path ($name + '.psd1')) -RootModule ((Split-Path -Leaf $name) + '.psm1') -ModuleVersion '2.0.0' -Author 'Fixture' -Description 'Release fixture' -PowerShellVersion '7.6' -CompatiblePSEditions Core
        }
        $path
    }
}
Describe 'Stable release identity' {
    BeforeEach { $script:VersionFixture = ReleaseFixture }
    It 'accepts matching root and implementation versions' {
        $result = & $ReleaseCheck -ModuleRoot $VersionFixture -Tag v2.0.0
        $result.Name | Should -BeExactly 'FrenchExDev.QuietCli.PoSh'
        $result.Version | Should -BeExactly '2.0.0'
    }
    It 'rejects an invalid stable tag <Tag>' -ForEach @(
        @{Tag='2.0.0'}, @{Tag='quietcli-v2.0.0'}, @{Tag='v2.0'}, @{Tag='v2.0.0-beta1'}, @{Tag='v02.0.0'}, @{Tag='v2.0.0.0'}
    ) {
        { & $ReleaseCheck -ModuleRoot $VersionFixture -Tag $Tag } | Should -Throw '*vX.Y.Z*'
    }
    It 'rejects a root version different from the tag' {
        { & $ReleaseCheck -ModuleRoot $VersionFixture -Tag v2.0.1 } | Should -Throw '*Tag/version mismatch*'
    }
    It 'rejects an implementation version different from the root' {
        $path = Join-Path $VersionFixture 'src/QuietCli.psd1'
        (Get-Content $path -Raw).Replace("'2.0.0'", "'2.0.1'") | Set-Content $path
        { & $ReleaseCheck -ModuleRoot $VersionFixture -Tag v2.0.0 } | Should -Throw '*src/QuietCli.psd1*'
    }
    It 'rejects a missing implementation manifest' {
        Remove-Item (Join-Path $VersionFixture 'src/QuietCli.psd1')
        { & $ReleaseCheck -ModuleRoot $VersionFixture -Tag v2.0.0 } | Should -Throw '*Missing release manifest*'
    }
    It 'rejects prerelease metadata under a stable tag' {
        Update-ModuleManifest -Path (Join-Path $VersionFixture 'FrenchExDev.QuietCli.PoSh.psd1') -Prerelease beta1
        { & $ReleaseCheck -ModuleRoot $VersionFixture -Tag v2.0.0 } | Should -Throw '*prerelease manifest*'
    }
}
Describe 'Clean distribution inventory' {
    BeforeEach { $script:InventoryFixture = ReleaseFixture }
    It 'keeps runtime resources and notices while excluding nested local state' {
        foreach ($relative in @('src/.git/config','src/artifacts/run.json','resources/local.sqlite3','resources/local.sqlite3-wal','fixtures/downloads/old.zip','resources/runtime/probe.dat')) {
            $path = Join-Path $InventoryFixture $relative
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $path))
            [IO.File]::WriteAllText($path,'fixture')
        }
        $report = & $ArchiveBuilder -ModuleRoot $InventoryFixture -ValidateOnly | ConvertFrom-Json
        $paths = @($report.Data.Manifest.Files.Path)
        $paths | Should -Contain 'resources/runtime/probe.dat'
        $paths | Should -Contain 'THIRD-PARTY-NOTICES.md'
        @($paths | Where-Object { $_ -match '\.git/|artifacts/|downloads/|local\.sqlite' }).Count | Should -Be 0
        $report.Data.Manifest.ModulePath | Should -BeExactly '.'
    }
    It 'rejects a missing required license file' {
        Remove-Item (Join-Path $InventoryFixture 'LICENSE')
        { & $ArchiveBuilder -ModuleRoot $InventoryFixture -ValidateOnly } | Should -Throw '*Missing package file: LICENSE*'
    }
}
Describe 'Verified ZIP to NuGet package' {
    BeforeAll {
        $script:BuildActions = $env:GITHUB_ACTIONS
        $env:GITHUB_ACTIONS = 'true'
        $script:BuildVersion = (Import-PowerShellDataFile (Join-Path $ReleaseRoot 'FrenchExDev.QuietCli.PoSh.psd1')).ModuleVersion
        $script:BuildTag = 'v' + $BuildVersion
        $script:BuildOutput = Join-Path $TestDrive 'release-assets'
        $null = & $ArchiveBuilder -OutputDirectory $BuildOutput -SourceRef $BuildTag -SourceCommitBase ('a' * 40)
        $script:BuildManifest = Join-Path $BuildOutput 'QuietCli.manifest.json'
        $script:BuildArchive = Join-Path $BuildOutput 'QuietCli.zip'
        $script:BuildResult = & $PackageBuilder -ArchivePath $BuildArchive -ManifestPath $BuildManifest -OutputDirectory $BuildOutput -Tag $BuildTag | ConvertFrom-Json
    }
    AfterAll { $env:GITHUB_ACTIONS = $BuildActions }
    It 'creates an installable package from the tested archive' {
        $BuildResult.Outcome | Should -Be Success
        $metadata = Get-Content $BuildManifest -Raw | ConvertFrom-Json
        $metadata.PackageFile | Should -BeExactly ('FrenchExDev.QuietCli.PoSh.' + $BuildVersion + '.nupkg')
        (Get-FileHash $BuildResult.Data.Package -Algorithm SHA256).Hash | Should -Be $metadata.PackageSHA256
        $zipReport = Get-Content (Join-Path $BuildOutput 'archive-verification.json') -Raw | ConvertFrom-Json
        $packageReport = Get-Content (Join-Path $BuildOutput 'package-verification.json') -Raw | ConvertFrom-Json
        $zipReport.FreshProcess | Should -BeTrue
        $packageReport.FreshProcess | Should -BeTrue
        $packageReport.VerifiedFiles | Should -Be $zipReport.VerifiedFiles
        $packageReport.Observation.Output | Should -BeExactly 'standalone'
        $packageReport.Observation.Version | Should -BeExactly $BuildVersion
        $packageReport.Observation.Tokenizer | Should -BeExactly $zipReport.Observation.Tokenizer
    }
    It 'contains the same source files as the ZIP, with no checkout or downloads' {
        $zip = [IO.Compression.ZipFile]::OpenRead($BuildResult.Data.Package)
        try {
            $entries = @($zip.Entries.FullName)
            $entries | Should -Contain 'FrenchExDev.QuietCli.PoSh.psd1'
            $entries | Should -Contain 'src/QuietCli.psm1'
            $entries | Should -Contain 'THIRD-PARTY-NOTICES.md'
            @($entries | Where-Object { $_ -match '(^|/)(?:\.git|downloads|artifacts|modules)/' }).Count | Should -Be 0
        } finally { $zip.Dispose() }
    }
    It 'installs from a local NuGet feed and imports by module name in a fresh process' {
        $repository = 'QuietCliTest-' + [guid]::NewGuid().ToString('N')
        $saved = Join-Path $TestDrive 'saved-module'
        [void][IO.Directory]::CreateDirectory($saved)
        Register-PSResourceRepository -Name $repository -Uri $BuildOutput -Trusted -ErrorAction Stop
        try {
            Save-PSResource -Name FrenchExDev.QuietCli.PoSh -Version $BuildVersion -Repository $repository -Path $saved -TrustRepository -ErrorAction Stop
            $installedRoot = Join-Path $saved ('FrenchExDev.QuietCli.PoSh/' + $BuildVersion)
            $metadata = Get-Content $BuildManifest -Raw | ConvertFrom-Json
            foreach ($file in @($metadata.Files | Where-Object { $_.Path -match '^resources/runtime/|^LICENSE$|^THIRD-PARTY-NOTICES.md$' })) {
                (Get-FileHash -LiteralPath (Join-Path $installedRoot $file.Path) -Algorithm SHA256).Hash | Should -Be $file.SHA256
            }
            $body = @'
$ErrorActionPreference='Stop'
$env:PSModulePath='__SAVED__'+[IO.Path]::PathSeparator+$env:PSModulePath
$env:QUIETCLI_TRACKING='0';$env:QUIETCLI_RECALL='0'
Import-Module FrenchExDev.QuietCli.PoSh -RequiredVersion '__VERSION__' -DisableNameChecking
$module=Get-Module FrenchExDev.QuietCli.PoSh
$measurement=Measure-QuietToken -Text hello
@{Version=$module.Version.ToString();ModuleBase=$module.ModuleBase;Tokens=$measurement.Tokens}|ConvertTo-Json -Compress
'@
            $body = $body.Replace('__SAVED__',$saved.Replace("'","''")).Replace('__VERSION__',$BuildVersion)
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($body))
            $result = pump -AsObject -Parse {param($capture) $capture.Stdout|ConvertFrom-Json} (Get-Process -Id $PID).Path -NoProfile -EncodedCommand $encoded
            $result.Outcome | Should -Be Success
            $result.Data.Version | Should -BeExactly $BuildVersion
            $result.Data.ModuleBase | Should -BeExactly $installedRoot
            $result.Data.Tokens | Should -Be 1
        } finally { Unregister-PSResourceRepository -Name $repository -ErrorAction Stop }
    }
    It 'rejects a corrupted ZIP before creating a package' {
        $corrupt = Join-Path $TestDrive 'corrupt.zip'
        [IO.File]::WriteAllText($corrupt,'not the verified ZIP')
        { & $PackageBuilder -ArchivePath $corrupt -ManifestPath $BuildManifest -OutputDirectory (Join-Path $TestDrive 'corrupt-output') -Tag $BuildTag } | Should -Throw '*Archive SHA256 mismatch*'
    }
    It 'rejects the wrong source tag' {
        { & $PackageBuilder -ArchivePath $BuildArchive -ManifestPath $BuildManifest -OutputDirectory (Join-Path $TestDrive 'wrong-tag') -Tag v99.0.0 } | Should -Throw '*source tag*'
    }
}
Describe 'Gallery publication without network access' {
    BeforeAll {
        $script:PublishActions = $env:GITHUB_ACTIONS
        $script:PublishKey = $env:PSGALLERY_API_KEY
        $script:PublishRoot = ReleaseFixture
        $script:PublishOutput = Join-Path $TestDrive 'publish-assets'
        [void][IO.Directory]::CreateDirectory($PublishOutput)
        $specification = '<package><metadata><id>FrenchExDev.QuietCli.PoSh</id><version>2.0.0</version></metadata></package>'
        [IO.File]::WriteAllText((Join-Path $PublishRoot 'FrenchExDev.QuietCli.PoSh.nuspec'),$specification)
        $script:PublishPackage = Join-Path $PublishOutput 'FrenchExDev.QuietCli.PoSh.2.0.0.nupkg'
        [IO.Compression.ZipFile]::CreateFromDirectory($PublishRoot,$PublishPackage)
        $script:PublishManifest = Join-Path $PublishOutput 'QuietCli.manifest.json'
        @{ ModuleVersion='2.0.0'; SourceRef='v2.0.0'; PackageFile=(Split-Path -Leaf $PublishPackage); PackageSHA256=(Get-FileHash $PublishPackage -Algorithm SHA256).Hash } | ConvertTo-Json | Set-Content $PublishManifest
    }
    BeforeEach {
        $env:GITHUB_ACTIONS = 'true'
        $env:PSGALLERY_API_KEY = 'unit-test-placeholder'
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode=404 } }
        Mock Publish-PSResource {}
    }
    AfterAll {
        $env:GITHUB_ACTIONS = $PublishActions
        $env:PSGALLERY_API_KEY = $PublishKey
    }
    It 'publishes the exact verified nupkg when the version is absent' {
        $result = & $Publisher -PackagePath $PublishPackage -ManifestPath $PublishManifest -ModuleRoot $PublishRoot -Tag v2.0.0 -Confirm:$false | ConvertFrom-Json
        $result.Outcome | Should -Be Success
        Should -Invoke Publish-PSResource -Exactly -Times 1 -ParameterFilter { $NupkgPath -eq $script:PublishPackage -and $Repository -eq 'PSGallery' }
    }
    It 'rejects a missing API key before contacting the Gallery' {
        $env:PSGALLERY_API_KEY = ''
        { & $Publisher -PackagePath $PublishPackage -ManifestPath $PublishManifest -ModuleRoot $PublishRoot -Tag v2.0.0 } | Should -Throw '*PSGALLERY_API_KEY*'
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Publish-PSResource -Times 0
    }
    It 'rejects an already published version without overwriting it' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode=200 } }
        { & $Publisher -PackagePath $PublishPackage -ManifestPath $PublishManifest -ModuleRoot $PublishRoot -Tag v2.0.0 } | Should -Throw '*already published*'
        Should -Invoke Publish-PSResource -Times 0
    }
    It 'fails closed on a Gallery service error' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode=503 } }
        { & $Publisher -PackagePath $PublishPackage -ManifestPath $PublishManifest -ModuleRoot $PublishRoot -Tag v2.0.0 } | Should -Throw '*HTTP 503*'
        Should -Invoke Publish-PSResource -Times 0
    }
    It 'does not publish during a WhatIf execution' {
        & $Publisher -PackagePath $PublishPackage -ManifestPath $PublishManifest -ModuleRoot $PublishRoot -Tag v2.0.0 -WhatIf | Out-Null
        Should -Invoke Publish-PSResource -Times 0
    }
    It 'rejects a changed package before contacting the Gallery' {
        $changed = Join-Path $TestDrive 'changed'
        [void][IO.Directory]::CreateDirectory($changed)
        $path = Join-Path $changed (Split-Path -Leaf $PublishPackage)
        [IO.File]::WriteAllText($path,'changed package')
        { & $Publisher -PackagePath $path -ManifestPath $PublishManifest -ModuleRoot $PublishRoot -Tag v2.0.0 } | Should -Throw '*Package SHA256 mismatch*'
        Should -Invoke Invoke-WebRequest -Times 0
    }
}
Describe 'Release workflow connections' {
    BeforeAll {
        Import-Module powershell-yaml -RequiredVersion 0.4.12
        $script:ReleaseWorkflow = Get-Content (Join-Path $ReleaseRoot '.github/workflows/release.yml') -Raw | ConvertFrom-Yaml
        $script:TestWorkflow = Get-Content (Join-Path $ReleaseRoot '.github/workflows/quietcli.yml') -Raw | ConvertFrom-Yaml
    }
    It 'uses the Linux CI as a reusable gate and passes its source location' {
        $TestWorkflow.on.workflow_call.outputs.'module-dir'.value | Should -BeExactly '${{ jobs.linux.outputs.module-dir }}'
        $ReleaseWorkflow.jobs.test.uses | Should -BeExactly './.github/workflows/quietcli.yml'
        $ReleaseWorkflow.jobs.package.needs | Should -Be test
        $ReleaseWorkflow.jobs.publish.needs | Should -Contain package
        $TestWorkflow.jobs.linux.container.options | Should -BeExactly '--init'
        $ReleaseWorkflow.jobs.package.container.options | Should -BeExactly '--init'
        $ReleaseWorkflow.jobs.publish.container.options | Should -BeExactly '--init'
    }
    It 'starts every Linux job on Alpine without requiring a custom image variable' {
        $jobs = @($TestWorkflow.jobs.linux, $ReleaseWorkflow.jobs.package, $ReleaseWorkflow.jobs.publish)
        foreach ($job in $jobs) {
            $job.container.image | Should -BeExactly '${{ vars.QUIETCLI_LINUX_IMAGE || ''alpine:3.24'' }}'
            $job.steps[0].name | Should -BeExactly 'Prepare Git for checkout'
            $job.steps[0].shell | Should -BeExactly sh
            $checkout = -1
            $initialize = -1
            for ($index = 0; $index -lt $job.steps.Count; $index++) {
                if ($job.steps[$index].uses -eq 'actions/checkout@v4') { $checkout = $index }
                if ($job.steps[$index].name -eq 'Initialize PowerShell 7.6+ Core') { $initialize = $index }
            }
            $checkout | Should -BeGreaterThan 0
            $initialize | Should -BeGreaterThan $checkout
            $job.steps[$initialize].shell | Should -BeExactly sh
            $job.steps[$initialize].run | Should -Match 'Initialize-QuietCliLinux.sh'
        }
        $TestWorkflow.jobs.Keys | Should -Not -Contain runtime
    }
    It 'triggers on version tags and limits release write permission to publication' {
        $ReleaseWorkflow.on.push.tags | Should -Contain 'v*'
        $ReleaseWorkflow.permissions.contents | Should -Be read
        $ReleaseWorkflow.jobs.publish.permissions.contents | Should -Be write
        @($TestWorkflow.jobs.Keys | Where-Object { $_ -in @('gallery','release-assets') }).Count | Should -Be 0
    }
}
