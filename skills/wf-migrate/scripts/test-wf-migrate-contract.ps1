param(
    [string]$RepositoryPath = "C:\Users\dzmitry_klim\IdeaProjects\sherpa2\sherpa\rpa-suite"
)

$ErrorActionPreference = "Stop"
$expectedDesignerVersion = "1.4.4.39274"
$skillRoot = Split-Path -Parent $PSScriptRoot
$migrationScriptPath = Join-Path $PSScriptRoot "wf-migrate.ps1"
$skillPath = Join-Path $skillRoot "SKILL.md"
$resourcesPath = Join-Path $RepositoryPath "buildSrc\src\main\resources"
$sherpaTemplatePath = Join-Path $resourcesPath '${process_pretty_name}.sherpa'
$processTemplatePath = Join-Path $resourcesPath "Главная.process"
$failures = New-Object System.Collections.Generic.List[string]
$passes = New-Object System.Collections.Generic.List[string]

function Assert-Contract {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        $script:passes.Add($Message)
        return
    }
    $script:failures.Add($Message)
}

function Get-BlockSettings {
    param([string]$Path)

    $encoded = [System.IO.File]::ReadAllText($Path)
    $decoded = [System.Net.WebUtility]::HtmlDecode($encoded)
    return [xml]$decoded
}

$skillText = [System.IO.File]::ReadAllText($skillPath)
$migrationScriptText = [System.IO.File]::ReadAllText($migrationScriptPath)
Assert-Contract ($skillText -match [regex]::Escape('$ExpectedProductVersion   = "' + $expectedDesignerVersion + '"')) "SKILL.md expects ProductVersion $expectedDesignerVersion"
Assert-Contract ($skillText -match [regex]::Escape('$ExpectedDesignerExeVersion = "' + $expectedDesignerVersion + '"')) "SKILL.md expects Designer EXE $expectedDesignerVersion"
Assert-Contract ($migrationScriptText -match [regex]::Escape('$script:ExpectedProductVersion   = "' + $expectedDesignerVersion + '"')) "wf-migrate.ps1 expects ProductVersion $expectedDesignerVersion"
Assert-Contract ($migrationScriptText -match [regex]::Escape('$script:ExpectedDesignerExeVersion = "' + $expectedDesignerVersion + '"')) "wf-migrate.ps1 expects Designer EXE $expectedDesignerVersion"

$designerPath = "C:\Program Files\Sherpa RPA\Designer\DiagramDesigner.exe"
Assert-Contract (Test-Path -LiteralPath $designerPath) "Designer executable exists"
if (Test-Path -LiteralPath $designerPath) {
    $installedVersion = (Get-Item -LiteralPath $designerPath).VersionInfo.FileVersion
    Assert-Contract ($installedVersion -eq $expectedDesignerVersion) "Installed Designer EXE is $expectedDesignerVersion (found $installedVersion)"
}

$sherpaTemplate = [System.IO.File]::ReadAllText($sherpaTemplatePath) | ConvertFrom-Json
Assert-Contract ($sherpaTemplate.ProductVersion -eq $expectedDesignerVersion) "Gradle .sherpa template ProductVersion is $expectedDesignerVersion (found $($sherpaTemplate.ProductVersion))"
Assert-Contract ($null -ne $sherpaTemplate.References.Items) "Gradle .sherpa template has References.Items"
Assert-Contract ($null -ne $sherpaTemplate.Folders) "Gradle .sherpa template has Folders"

$processTemplate = [xml][System.IO.File]::ReadAllText($processTemplatePath)
foreach ($section in @("DesignerItems", "Connections", "Properties", "PSCache", "Description", "InputArguments", "OutputArguments")) {
    Assert-Contract ($null -ne $processTemplate.Root.$section) "Gradle process template has $section"
}

$canonicalVersions = @{
    "end_block_template.txt" = "113"
    "fullabort_block_template.txt" = "36"
    "handleerror_block_template.txt" = "37"
    "receive_robot_task_block_template.txt" = "32"
    "step_block_template.txt" = "495"
    "switch_case_block_template.txt" = "42"
    "trycatch_block_template.txt" = "102"
}
foreach ($entry in $canonicalVersions.GetEnumerator()) {
    $path = Join-Path $PSScriptRoot $entry.Key
    $settings = Get-BlockSettings -Path $path
    Assert-Contract ($settings.ToolboxItemSettings.Version -eq $entry.Value) "$($entry.Key) uses canonical block version $($entry.Value)"
}

$stepSettings = Get-BlockSettings -Path (Join-Path $PSScriptRoot "step_block_template.txt")
$stepProperties = @($stepSettings.SelectNodes("//*[local-name()='Property']"))
$requiredStepProperties = @{
    "StepName" = "Expression"
    "InitParamsAssetName" = "Expression"
    "EmailTemplatesAssetName" = "Expression"
    "Args" = "Expression"
    "RetryDelayMs" = "Int64"
    "SaveTransaction" = "Bool"
    "ConnectSAP" = "Bool"
}
foreach ($entry in $requiredStepProperties.GetEnumerator()) {
    $property = $stepProperties | Where-Object { $_.Name -eq $entry.Key }
    Assert-Contract (($null -ne $property) -and ($property.Type -eq $entry.Value)) "Java Step has $($entry.Key) property of type $($entry.Value)"
}
Assert-Contract (($stepProperties | Where-Object Name -eq "RetryDelayMs").Value -eq "1000") "Java Step RetryDelayMs defaults to 1000"
Assert-Contract (($stepProperties | Where-Object Name -eq "ConnectSAP").Value -eq "False") "Java Step ConnectSAP defaults to False"

$nonMtContracts = @(
    "Non-MT canonical diagram templates — Try/Catch, HandleError, Прервать.",
    "No queue block (OrchGetDefaultTask/ReceiveRobotTask) — those are MT-only.",
    "SaveTransaction=True only",
    "Repair-JavaStepArgs"
)
foreach ($contract in $nonMtContracts) {
    Assert-Contract ($migrationScriptText.Contains($contract)) "Non-MT generator contract contains: $contract"
}
Assert-Contract ($migrationScriptText -match 'Value="&amp;quot;&amp;quot;"') "Non-MT generator can emit empty Java Step Args"
Assert-Contract ($migrationScriptText -match "SaveTransaction[^\r\n]+Value=.+False") "Non-MT generator disables SaveTransaction after the first Step"
Assert-Contract ($migrationScriptText.Contains('$productVersion = $script:ExpectedProductVersion')) "Generated .sherpa uses the canonical expected ProductVersion"

foreach ($message in $passes) {
    Write-Host "PASS: $message" -ForegroundColor Green
}
foreach ($message in $failures) {
    Write-Host "FAIL: $message" -ForegroundColor Red
}
Write-Host "Contract checks: $($passes.Count) passed, $($failures.Count) failed"

if ($failures.Count -gt 0) {
    exit 1
}
