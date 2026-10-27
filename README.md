# QuietCli

**Faites lire à votre agent IA le résultat utile d’une commande. Calculez ce résultat localement.**

QuietCli est un module **PowerShell 7.4+ Core** pour écrire des **scripts compagnons** : ils exécutent vos outils, analysent leurs sorties et renvoient un seul résultat JSON avec un budget explicite. L’agent définit la question ; le script calcule la réponse ; QuietCli gère les processus, les deux flux et l’enveloppe du résultat.

```text
Question : « Ce dépôt nécessite-t-il une revue ? »

git branch + git status
        ↓ analyse locale dans un script compagnon
{ Branch: "main", Changed: 1, Untracked: 1, Clean: false }
        ↓ une enveloppe JSON bornée
L’agent dispose des faits nécessaires pour décider.
```

**5 fonctions publiques · JSON borné en UTF-8 · tâches composables · licence MIT**

[Démarrer](#démarrer) · [Charger au démarrage](#charger-quietcli-au-démarrage-de-pwsh) · [Exemple Git](#exemple-concret--contrôler-un-dépôt-git) · [Créer un compagnon](#écrire-votre-premier-compagnon) · [API](#les-cinq-fonctions-publiques) · [Dépannage](#dépannage)

## Pourquoi QuietCli ?

Une sortie de terminal mélange souvent progression, diagnostics et données. QuietCli permet de traiter ce texte dans un programme local et d’envoyer à l’IA une réponse adaptée à la demande.

| Votre question | Le script calcule et retourne |
| --- | --- |
| Le dépôt est-il propre ? | Branche, entrées modifiées, entrées non suivies, indicateur `Clean`. |
| Les validations ont-elles réussi ? | Totaux, échecs et diagnostics sélectionnés. |
| Combien d’éléments correspondent ? | Nombre, périmètre, unité et état de complétude. |
| La préparation autorise-t-elle l’étape suivante ? | Résultat de préparation, décision locale, résultat de validation. |

La propriété `.Data` est libre : un objet métier, un tableau, un scalaire ou `null`. Vous décidez des informations nécessaires et conservez les calculs intermédiaires dans le script.

## Démarrer

### Prérequis

| Composant | Quand est-il nécessaire ? |
| --- | --- |
| **PowerShell 7.4+ Core**, exécutable `pwsh` | Pour le module et les compagnons PowerShell. Windows PowerShell 5.1 ne convient pas. |
| **Git** dans le `PATH` | Pour les exemples Git. |
| **Python 3** | Pour la démonstration bruyante et la suite d’intégration complète. |
| Bash, awk, jq et GNU `timeout` | Pour le compagnon Bash et ses vérifications sous Linux. |

Le module PowerShell n’a aucune dépendance à un module tiers. Son code C# est chargé à l’import ; aucun SDK .NET à installer séparément. Un éditeur particulier n’est pas requis.

### 1. Obtenir le module

**Depuis ce workspace**, copiez ce bloc dans `pwsh` :

```powershell
$moduleRoot = 'C:/code/FrenchExDev/FrenchExDev_i2/PoSh/FrenchExDev/FrenchExDev.QuietCli.PoSh'
$moduleRoot = (Resolve-Path -LiteralPath $moduleRoot -ErrorAction Stop).Path
Import-Module (Join-Path $moduleRoot 'QuietCli.PoSh.psd1') -ErrorAction Stop
Get-Command -Module QuietCli.PoSh
```

Adaptez la première ligne à l’emplacement de votre checkout. Le fichier à importer s’appelle bien **`QuietCli.PoSh.psd1`**.

**Sans checkout**, téléchargez le [bundle QuietCli.zip](downloads/QuietCli.zip), enregistrez-le dans votre dossier de téléchargements, puis extrayez-le vers un emplacement durable :

```powershell
# Adaptez ce chemin à l’emplacement réel du téléchargement.
$archive = Join-Path $HOME 'Downloads/QuietCli.zip'
$installRoot = Join-Path $HOME '.local/share/quietcli'
if (Test-Path -LiteralPath (Join-Path $installRoot 'QuietCli')) {
    throw 'QuietCli existe déjà ici. Choisissez un autre dossier pour cette extraction.'
}
Expand-Archive -LiteralPath $archive -DestinationPath $installRoot -ErrorAction Stop
$moduleRoot = (Resolve-Path -LiteralPath (Join-Path $installRoot 'QuietCli')).Path
Import-Module (Join-Path $moduleRoot 'QuietCli.PoSh.psd1') -ErrorAction Stop
Get-Command -Module QuietCli.PoSh
```

Le ZIP contient le runtime, le skill, les exemples, les fixtures et le lanceur de vérification. Conservez son `package-manifest.json` et le [manifeste de distribution](downloads/QuietCli.manifest.json), qui identifient les contenus par SHA-256. Le README du checkout et celui d’une archive précédemment générée peuvent correspondre à des révisions différentes.

### 2. Obtenir un premier résultat

Dans la même session, indiquez **un dépôt Git existant** :

```powershell
$repository = 'C:/code/my-project' # À remplacer.
& (Join-Path $moduleRoot 'examples/Generated-GitOverview.ps1') `
    -Repository $repository -MaxOutputBytes 2048
```

Vous obtenez un document JSON avec `Outcome`, `Data`, `Execution`, `Error` et `Truncation`. L’[exemple reproductible](#exemple-concret--contrôler-un-dépôt-git) ci-dessous crée son propre dépôt si vous préférez essayer sans toucher à votre projet.

## Charger QuietCli au démarrage de pwsh

PowerShell distingue le profil de l’hôte courant (`$PROFILE`) du profil commun aux hôtes de l’utilisateur (`$PROFILE.CurrentUserAllHosts`). Pour retrouver QuietCli dans la console et dans les autres hôtes PowerShell, utilisez le second. Les profils et leur ordre de chargement sont décrits dans la [documentation PowerShell](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_profiles).

**Après l’une des installations précédentes**, exécutez ce bloc. Il utilise `$moduleRoot`, valide le manifeste, sauvegarde le profil existant et ajoute une section identifiée une seule fois :

```powershell
$quietCliManifest = (Resolve-Path -LiteralPath (
    Join-Path $moduleRoot 'QuietCli.PoSh.psd1'
) -ErrorAction Stop).Path
$profilePath = $PROFILE.CurrentUserAllHosts
$marker = '# >>> QuietCli >>>'
$profileText = if (Test-Path -LiteralPath $profilePath) {
    [string](Get-Content -LiteralPath $profilePath -Raw)
} else { '' }

if ($profileText.Contains($marker)) {
    Write-Host "Une section QuietCli existe déjà dans $profilePath. Vérifiez son chemin si vous avez déplacé le module."
} else {
    New-Item -ItemType Directory -Path (Split-Path -Parent $profilePath) -Force | Out-Null
    if (Test-Path -LiteralPath $profilePath) {
        $backupPath = '{0}.{1}.bak' -f $profilePath, (Get-Date -Format 'yyyyMMdd-HHmmss-fffffff')
        Copy-Item -LiteralPath $profilePath -Destination $backupPath -ErrorAction Stop
    }
    $profileBlock = @"
# >>> QuietCli >>>
Import-Module '__QUIETCLI_MANIFEST__' -ErrorAction Stop
# <<< QuietCli <<<
"@
    $profileBlock = $profileBlock.Replace('__QUIETCLI_MANIFEST__', $quietCliManifest.Replace("'", "''"))
    Add-Content -LiteralPath $profilePath -Value ("`n" + $profileBlock) -Encoding utf8
}

# Charger la configuration dans la session actuelle.
. $profilePath
Get-Command Invoke-QuietCli, Invoke-QuietTask, Invoke-QuietStep
```

Le profil contient un **chemin absolu**, correctement cité, et fonctionne sans les variables de la session d’installation. Ouvrez ensuite un nouveau terminal avec `pwsh` pour vérifier le chargement au démarrage.

Un processus lancé avec `pwsh -NoProfile` ignore les profils ; ses scripts doivent importer le module eux-mêmes. Les compagnons fournis le font déjà. Les sessions distantes ne chargent pas non plus automatiquement votre profil local. Pour limiter le chargement à l’hôte courant, remplacez `$PROFILE.CurrentUserAllHosts` par `$PROFILE` dans le bloc d’installation.

Pour déplacer ou désactiver l’installation, éditez la section comprise entre les deux marqueurs dans `$profilePath`. Les commandes restent chargées dans les sessions déjà ouvertes jusqu’à leur fermeture ou au déchargement du module.

## Exemple concret : contrôler un dépôt Git

**Objectif :** obtenir la branche, le nombre d’entrées modifiées et non suivies, puis savoir si le dépôt est propre. Le compagnon fourni combine deux observations Git et livre un seul JSON de **2 048 octets maximum**.

### Créer un cas reproductible

Ce bloc crée un nouveau dossier temporaire, un commit local, une modification et un dossier non suivi. Aucun dépôt existant n’est utilisé. Git doit être installé ; `$moduleRoot` provient du démarrage ci-dessus.

```powershell
$demoRepo = Join-Path ([IO.Path]::GetTempPath()) ('quietcli-demo-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $demoRepo | Out-Null
git init --quiet --initial-branch=main $demoRepo
if ($LASTEXITCODE -ne 0) { throw 'Échec de git init.' }

Set-Content -LiteralPath (Join-Path $demoRepo 'app.txt') -Value 'version 1'
git -C $demoRepo add app.txt
if ($LASTEXITCODE -ne 0) { throw 'Échec de git add.' }
git -C $demoRepo -c user.name=QuietCli -c user.email=demo@example.invalid `
    -c commit.gpgsign=false -c core.hooksPath= `
    commit --quiet -m 'Initial demo'
if ($LASTEXITCODE -ne 0) { throw 'Échec du commit de démonstration.' }

Set-Content -LiteralPath (Join-Path $demoRepo 'app.txt') -Value 'version 2'
New-Item -ItemType Directory -Path (Join-Path $demoRepo 'notes') | Out-Null
Set-Content -LiteralPath (Join-Path $demoRepo 'notes/a.txt') -Value 'première note'
Set-Content -LiteralPath (Join-Path $demoRepo 'notes/b.txt') -Value 'seconde note'

$json = & (Join-Path $moduleRoot 'examples/Generated-GitOverview.ps1') `
    -Repository $demoRepo -MaxOutputBytes 2048
$json
```

Dans l’enveloppe retournée, `.Data` vaut :

```json
{
  "Branch": "main",
  "Detached": false,
  "Changed": 1,
  "Untracked": 1,
  "Clean": false,
  "AnswerComplete": true
}
```

`Changed` compte les **entrées de statut suivies**, pas les lignes modifiées. `Untracked` compte les entrées de `git status --untracked-files=normal` : le dossier `notes/` vaut **une entrée**, même s’il contient deux fichiers. Les fichiers ignorés ne sont pas comptés. Le compagnon gère les enregistrements terminés par NUL et les renommages, conformément au [format porcelain de Git](https://git-scm.com/docs/git-status).

### Exploiter le résultat dans votre script

```powershell
$result = $json | ConvertFrom-Json -ErrorAction Stop
if ($result.Outcome -ne 'Success' -or
    !$result.Execution.AnalysisComplete -or
    $result.Truncation.Applied -or
    $null -eq $result.Data -or
    !$result.Data.AnswerComplete) {
    throw "Résultat insuffisant : $($result.Outcome). Inspectez Error et Truncation."
}

if ($result.Data.Clean) {
    'Dépôt propre.'
} else {
    'Revue nécessaire : {0} entrée(s) modifiée(s), {1} non suivie(s).' -f `
        $result.Data.Changed, $result.Data.Untracked
}
```

Pour ce cas, la réponse est : `Revue nécessaire : 1 entrée(s) modifiée(s), 1 non suivie(s).`

Les observations sont séquentielles et ne constituent pas un instantané atomique. Un dépôt peut évoluer entre deux commandes. En HEAD détachée, `Branch` vaut `null` et `Detached` vaut `true` ; cela n’est pas une erreur d’exécution.

Pour une projection incluant aussi le commit et une décision `NeedsReview`, utilisez [Invoke-RepositoryDecision.ps1](examples/Invoke-RepositoryDecision.ps1). Ce compagnon réutilise le premier et vérifie son enveloppe avant de poursuivre ; il nécessite un dépôt ayant déjà un commit.

## Utiliser QuietCli avec votre agent IA

Le [skill quiet-cli](skills/quiet-cli/SKILL.md) décrit comment préparer ou réutiliser un compagnon. Donnez à l’agent **le fichier d’instructions et le chemin du runtime installé**. Télécharger le skill seul ne fournit pas le module.

Exemple de demande prête à adapter :

```text
Lis le fichier <chemin-module>/skills/quiet-cli/SKILL.md.
Le runtime est <chemin-module>/QuietCli.PoSh.psd1.

Dans le dépôt <chemin-projet>, je veux la branche, les nombres d’entrées
modifiées et non suivies, et un booléen indiquant si le dépôt est propre.
Réutilise examples/Generated-GitOverview.ps1 si son périmètre convient.
Exécute localement le compagnon et retourne un seul résultat JSON,
avec un budget total de 2048 octets. Préserve les échecs, les limites
et la signification des compteurs. Ne modifie pas le dépôt inspecté.
```

Charger le module dans `$PROFILE` rend ses fonctions disponibles dans les sessions concernées. L’agent doit encore choisir et appeler un compagnon : QuietCli ne configure aucun hook d’interception automatique des commandes.

## Écrire votre premier compagnon

Voici une version minimale qui répond à une seule question : **quelle est la branche courante ?** Elle utilise le [format documenté de `git branch --show-current`](https://git-scm.com/docs/git-branch). Exécutez-la après le démarrage, ou enregistrez-la dans un script qui importe explicitement le manifeste.

```powershell
$repository = $demoRepo # Ou le chemin absolu d’un autre dépôt Git.
Invoke-QuietTask -MaxOutputBytes 2048 -AsJson -ArgumentList @($repository) -ScriptBlock {
    param($repo)
    $branch = Invoke-QuietStep -Name 'branch' -ScriptBlock {
        Invoke-QuietCli -FilePath git -ArgumentList @('branch', '--show-current') `
            -WorkingDirectory $repo -Summary 'Branche courante extraite.' -Parse {
                param($capture)
                $name = $capture.Stdout.TrimEnd("`r", "`n")
                [pscustomobject]@{
                    Branch = $(if ($name.Length) { $name } else { $null })
                    Detached = ($name.Length -eq 0)
                }
            }
    }
    if ($branch.Outcome -ne 'Success') { return }
    [pscustomobject]@{
        Branch = $branch.Data.Branch
        Detached = $branch.Data.Detached
        AnswerComplete = $true
    }
}
```

`Invoke-QuietStep` inscrit le résultat dans la tâche, même si vous l’affectez à une variable. Après un échec, le script s’arrête avant de fabriquer une réponse métier. La tâche conserve cet échec dans son enveloppe finale. L’affectation seule d’un appel à `Invoke-QuietCli` ne l’enregistre pas comme étape : utilisez `Invoke-QuietStep`.

Le parseur reçoit la capture locale et retourne **un seul objet** ; pour retourner un tableau comme valeur unique, utilisez la virgule unaire (`return ,$items`). Ne retournez jamais la capture brute. Dans un réducteur streaming, `-OnRecord` met uniquement à jour l’état ; `-Complete` produit l’objet final.

## Traiter une commande très bavarde

Le compagnon [Generated-NoisyJob.ps1](examples/Generated-NoisyJob.ps1) exécute une préparation, puis une validation. Une fixture Python produit des événements sur stdout et des diagnostics sur stderr. Le script les consomme localement, vérifie les événements de fin et agrège les deux étapes.

```powershell
$companion = Join-Path $moduleRoot 'examples/Generated-NoisyJob.ps1'
pwsh -NoLogo -NoProfile -File $companion `
    -Python python3 -Records 2000 -MaxOutputBytes 2048
```

Utilisez `-Python python` ou le chemin absolu de Python 3 si nécessaire. Pour 2 000 éléments par étape, la projection contient `Prepared: 2000`, `Validated: 2000` et les compteurs de chaque étape.

La [mesure fournie](verification/demo-measurements.json) rapporte **4 000 événements de progression et 4 000 diagnostics consommés**, puis un JSON final de **533 octets** hors saut de ligne. C’est une observation enregistrée avec PowerShell 7.4.20 ; la taille peut varier, notamment avec la durée d’exécution. Elle ne mesure pas les économies totales de tokens ou d’argent.

## Les cinq fonctions publiques

| Fonction | Rôle | Paramètres utiles |
| --- | --- | --- |
| `Invoke-QuietCli` | Exécuter un programme natif et analyser ses deux flux. | `-FilePath`, `-ArgumentList`, `-WorkingDirectory`, `-Parse` ou `-OnRecord` / `-State` / `-Complete`, `-TimeoutSeconds`. |
| `Invoke-QuietStep` | Enregistrer un résultat dans la tâche courante. | `-Name`, `-ScriptBlock`. Nécessite une tâche active. |
| `Invoke-QuietTask` | Composer les étapes et émettre une projection finale. | `-ScriptBlock`, `-ArgumentList`, `-MaxItems`, `-MaxOutputBytes`, `-AsJson`. |
| `New-QuietResult` | Construire une enveloppe bornée avec vos propres données. | `-Summary`, `-Outcome`, `-Data`, `-Execution`, `-ErrorInfo`. |
| `ConvertTo-QuietJson` | Sérialiser une enveloppe en JSON compact avec contrôle du budget. | `-InputObject`, `-MaxOutputBytes`. |

Les signatures exactes sont dans le [runtime](src/QuietCli.psm1). Passez les arguments natifs dans un tableau ; le runtime les transmet sans shell implicite. Pour un script ou une syntaxe de shell, choisissez explicitement l’interpréteur.

### Deux modes de lecture

| Mode | Usage | Contrat |
| --- | --- | --- |
| **Document** : `-Parse` | Un document JSON ou une petite sortie complète. | Le parseur reçoit la capture après exécution. Une capture dépassant la limite est un échec `CaptureLimit`. |
| **Streaming** : `-OnRecord`, `-State`, `-Complete` | Des événements, lignes ou enregistrements nombreux. | Le réducteur tient des compteurs et un échantillon borné. Une perte d’enregistrements invalide l’analyse (`RecordLimit`). |

### Limites par défaut

| Paramètre | Défaut | Unité et portée |
| --- | --- | --- |
| `MaxOutputBytes` | `4096` | Octets UTF-8 pour l’enveloppe JSON ; plage `1024` à `65536`. |
| `MaxItems` | `20` | Valeurs de projection émises par le corps d’une tâche. Ne limite pas chaque tableau imbriqué dans `.Data`. |
| `TimeoutSeconds` | `600` | Secondes par appel natif. |
| `MaxCaptureCharacters` | `262144` | Caractères de capture en mode document. |
| `MaxRecordCharacters` | `65536` | Caractères par enregistrement en mode streaming. |

Le budget final doit couvrir **toute la réponse**, pas vingt sorties affichées séparément. Les objets intermédiaires QuietCli passent eux aussi par leur propre budget : une donnée omise à cette étape ne réapparaît pas en augmentant seulement le budget final. Pour les grandes données, calculez une projection plus petite ou travaillez en streaming.

## Lire correctement un résultat

| Champ | Ce qu’il indique |
| --- | --- |
| `SchemaVersion` | Version de l’enveloppe : `1`. |
| `Summary` | Résumé court de l’exécution. |
| `Outcome` | `Success`, `Failed`, `Timeout` ou `Unsupported`. |
| `Data` | Réponse métier définie par le compagnon. |
| `Execution` | Code de sortie, durée, état d’analyse et compteurs d’étapes selon le contexte. |
| `Error` | Diagnostic structuré, ou `null`. |
| `Truncation` | Indicateur `Applied` et raisons des omissions ou du masquage. |

Vérifiez ensemble **le statut**, **la complétude de l’analyse**, **la présence des faits métier** et **les omissions**. Un `Success` ne garantit pas que `.Data` répond à votre question. Une valeur inconnue reste `null`. Pour une tâche composée, `Execution.ExitCode` est `null` ; les compteurs décrivent les étapes.

| Situation | Interprétation et action |
| --- | --- |
| `Failed` / `NativeFailed` | Le programme a renvoyé un code non accepté. Vérifier le code, les arguments et les diagnostics sélectionnés. |
| `Failed` / `ParserFailed` | Le format ou le contrat du parseur est invalide. Corriger l’analyse. |
| `Timeout` | La commande n’a pas terminé dans le délai. Revoir le périmètre ou le délai avant toute nouvelle exécution. |
| `CaptureLimit` / `RecordLimit` | L’analyse ne dispose pas d’une source complète. Adapter le mode de lecture, le périmètre ou la limite. |
| `OutputBudget` | La transmission a dépassé le budget ; `.Data` peut être `null`. Réduire la projection ou augmenter explicitement le budget. |
| `SensitiveData` | Le runtime a masqué des valeurs sensibles reconnues. Inspecter ce qui reste exploitable. |

Les tâches composées regroupent les incidents sous `Error.Code = TaskFailed` et exposent les étapes concernées dans `Error.Issues`. Le runtime applique un masquage de secrets connus et des limites de champs ; sélectionnez aussi les diagnostics utiles dans vos compagnons, car ce masquage n’identifie pas toute donnée confidentielle possible.

Le résultat métier est décrit par l’enveloppe. Un script qui l’affiche peut se terminer avec un code de processus `0` tout en annonçant `Outcome: Failed` : un appelant doit lire l’enveloppe. Le lanceur de tests, lui, définit explicitement ses codes de sortie.

## QuietCli et RTK

Le [README de RTK](https://github.com/rtk-ai/rtk) présente une entrée rapide, des exemples concrets et une explication des gains. QuietCli reprend ici cette progression de lecture, avec un fonctionnement centré sur les compagnons.

| Besoin | RTK | QuietCli |
| --- | --- | --- |
| Réduire la sortie d’outils courants | Filtres et commandes fournis par RTK. | Parser et projection écrits ou réutilisés dans un compagnon. |
| Définir une réponse métier propre à la demande | Consulter les possibilités d’extension de la version RTK utilisée. | `.Data` est libre et calculée par votre script. |
| Enchaîner plusieurs observations | Dépend du workflow configuré. | Variables locales, conditions et étapes dans `Invoke-QuietTask`. |
| Charger l’outil au démarrage | Installation et intégration propres à RTK. | `Import-Module` dans le profil PowerShell ; appel explicite des compagnons. |

Pour évaluer un gain, comparez des tâches équivalentes avec le même tokenizer et la même réponse attendue. Comptez aussi la lecture des instructions, la génération du compagnon, son débogage et les relances. Séparez le coût de création de celui de la réutilisation. Une réduction d’octets de sortie ne suffit pas à établir une économie globale.

## Vérifier l’installation

La suite runtime n’a besoin ni de Python ni de Git :

```powershell
pwsh -NoLogo -NoProfile -File (Join-Path $moduleRoot 'test/Invoke-Tests.ps1') -RuntimeOnly
```

Pour la suite complète, installez les prérequis correspondant à votre environnement, puis choisissez votre exécutable Python :

```powershell
$testReport = Join-Path ([IO.Path]::GetTempPath()) 'quietcli-local-tests.json'
pwsh -NoLogo -NoProfile -File (Join-Path $moduleRoot 'test/Invoke-Tests.ps1') `
    -Python python3 -OutputPath $testReport
```

Le lanceur retourne un rapport JSON borné. Son code de sortie vaut `0` en cas de réussite, `1` en cas d’échec et `2` si un prérequis manque (`Unsupported`). Les cas Bash ignorés sous Windows sont comptés séparément.

Les rapports conservés, **datés du 14 octobre 2026**, décrivent les sources identifiées par leurs SHA-256 :

| Environnement enregistré | Runtime | Intégration | Rapport |
| --- | --- | --- | --- |
| Windows, PowerShell 7.6.6, Python 3.13.16 | 24 réussis | 5 réussis, 2 cas Bash ignorés | [Windows](verification/windows-tests.json) |
| Debian 13, PowerShell 7.4.20, Python 3.13.5 | 24 réussis | 7 réussis | [Linux](verification/linux-tests.json) |

Ces rapports sont des instantanés. Ils ne remplacent pas l’exécution de la suite sur votre version installée. Les vérifications couvrent notamment les échecs natifs, timeouts, sorties malformées, limites, tableaux vides ou unitaires, agrégation d’échecs et cas Git particuliers.

## Dépannage

| Symptôme | Vérification ou correction |
| --- | --- |
| « Aucun fichier de module valide » | Vérifier le chemin complet et le nom **`QuietCli.PoSh.psd1`**. Le nom du dossier n’est pas celui du manifeste. |
| Le module fonctionne ici, mais pas dans un nouveau terminal | Vérifier la section QuietCli dans `$PROFILE.CurrentUserAllHosts` et lancer `pwsh` sans `-NoProfile`. |
| Le terminal fonctionne, mais pas l’hôte PowerShell de VS Code | Vérifier que l’hôte utilise PowerShell 7 et charge le profil commun ; un profil propre à l’hôte peut ensuite modifier la session. |
| Le compagnon ne trouve pas Git ou Python | Vérifier le `PATH` du processus et le nom de l’exécutable. Utiliser un chemin absolu si nécessaire. |
| Un script téléchargé est bloqué sous Windows | Examiner la provenance et la politique effective avec `Get-ExecutionPolicy -List`. Si le fichier est approuvé et seulement marqué comme téléchargé, utiliser `Unblock-File -LiteralPath <fichier>`. |
| `.Data` vaut `null` | Lire `Outcome`, `Error` et `Truncation.Reasons` ; rechercher notamment `OutputBudget`. |
| Une étape échouée disparaît du bilan | Encadrer son appel avec `Invoke-QuietStep` dans `Invoke-QuietTask`. |
| Une modification du runtime semble ignorée | Recommencer dans un nouveau processus `pwsh -NoProfile` : les types C# déjà chargés restent présents dans la session. |

## Sources et exemples

| Ressource | Contenu |
| --- | --- |
| [Skill](skills/quiet-cli/SKILL.md) | Instructions à fournir à l’agent et contrats de compagnons. |
| [Manifeste](QuietCli.PoSh.psd1) et [runtime](src/QuietCli.psm1) | Version, exports et comportement exact. |
| [Session native C#](src/NativeSession.cs) | Exécution et lecture des flux. |
| [Git PowerShell](examples/Generated-GitOverview.ps1) et [Git Bash](examples/generated-git-status.sh) | Compagnons d’inspection de dépôt. |
| [Décision de revue](examples/Invoke-RepositoryDecision.ps1) | Réutilisation d’un compagnon et composition. |
| [Tâche bruyante](examples/Generated-NoisyJob.ps1) | Réduction streaming et validation de deux étapes. |
| [Lanceur de tests](test/Invoke-Tests.ps1) | Vérification runtime et intégration. |
| [Générateur d’archive](scripts/New-QuietCliArchive.ps1) | Reconstruction du ZIP et des empreintes de distribution. |

Pour contribuer, accompagnez les changements de parseur de cas de succès, d’échec, de format invalide et de limites. Conservez le sens des unités, le périmètre analysé et les informations nécessaires à la décision dans le contrat du compagnon.

Publié sous [licence MIT](LICENSE). Auteur : Stéphane Erard / FrenchExDev.
