#requires -Version 7.4
param([ValidateSet('json','malformed','fail','wait','capture','record')][string]$Mode='json')
switch($Mode) {
    json { [Console]::Out.Write('{"Count":3}') }
    malformed { [Console]::Out.Write('{broken') }
    fail { [Console]::Error.Write('fixture diagnostic');exit 7 }
    wait { Start-Sleep -Seconds 5;[Console]::Out.Write('{"Count":3}') }
    capture { [Console]::Out.Write(('x'*5000)) }
    record { [Console]::Out.Write(('x'*5000)+[Environment]::NewLine) }
}
