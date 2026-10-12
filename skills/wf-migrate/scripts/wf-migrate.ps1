#Requires -Version 5.1
<#
.SYNOPSIS
    Workfusion to Sherpa Migration Assistant
    Анализирует WF процесс и генерирует Sherpa RPA Suite проект.

.DESCRIPTION
    Скрипт сканирует директорию WF процесса, определяет типы шагов, Processor классы,
    зависимости, InitParams, DataKeys и при необходимости генерирует Java файлы
    для Sherpa проекта (InitParameters, ProcessDataKeys, ProcessTransaction, Step классы).

.PARAMETER WfProcessPath
    Путь к директории WF процесса (содержит *-bcb модуль)

.PARAMETER SherpaProjectName
    Желаемое имя Sherpa проекта (kebab-case)

.PARAMETER GenerateCode
    Если указан — сгенерировать Java файлы после анализа

.PARAMETER OutputPath
    Путь для сохранения сгенерированных файлов (default: <WfProcessPath>\..\..\sherpa\rpa-suite)

.PARAMETER PackageName
    Java пакет для сгенерированных классов (default: by.a1.<SherpaProjectName>)

.PARAMETER TransactionStorageFolder
    Плоская папка Orchestrator Storage для транзакционных файлов (default: transactions)

.EXAMPLE
    .\wf-migrate.ps1 -WfProcessPath "C:\wf_odf\ODF\<wf_process_dir>" -SherpaProjectName "<sherpa-project-name>" -GenerateCode
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$WfProcessPath,

    [Parameter(Mandatory=$false)]
    [string]$SherpaProjectName = "",

    [Parameter(Mandatory=$false)]
    [switch]$GenerateCode,

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = "",

    [Parameter(Mandatory=$false)]
    [string]$PackageName = "",

    [Parameter(Mandatory=$false)]
    [string]$RpaSuitePath = "",

    [Parameter(Mandatory=$false)]
    [string]$DesignerProjectName = "",

    [Parameter(Mandatory=$false)]
    [switch]$GenerateDesignerFiles,

    [Parameter(Mandatory=$false)]
    [string]$InitParamsAsset = "",

    [Parameter(Mandatory=$false)]
    [string]$EmailTemplatesAsset = "",

    [Parameter(Mandatory=$false)]
    [string]$StepArgs = ""
)

# === DESIGNER VERSION CONFIGURATION ===
# Update BOTH constants when Sherpa Designer is updated.
$script:ExpectedProductVersion   = "1.4.4.39274"
$script:ExpectedDesignerExeVersion = "1.4.4.39274"

# === CONFIGURATION ===
$ErrorActionPreference = "Stop"
$report = @{
    processPath = $WfProcessPath
    projectName = $SherpaProjectName
    steps = @()
    processors = @()
    services = @()
    dependencies = @()
    powerShellScripts = @()
    manualTaskFiles = @()
    manualTasks = @()
    initParams = @()
    dataKeys = @()
    errors = @()
    warnings = @()
}

function Write-ReportHeader {
    param([string]$Title)
    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
}

function Write-ReportItem {
    param([string]$Label, [string]$Value, [string]$Color = "White")
    Write-Host "  $Label`: " -NoNewline -ForegroundColor Gray
    Write-Host $Value -ForegroundColor $Color
}

function ConvertTo-PascalCase {
    param([string]$Name)
    $parts = $Name -split '_'
    return ($parts | ForEach-Object { $_.Substring(0,1).ToUpper() + $_.Substring(1).ToLower() }) -join ''
}

function ConvertTo-CamelCase {
    param([string]$Name)
    $pascal = ConvertTo-PascalCase $Name
    return $pascal.Substring(0,1).ToLower() + $pascal.Substring(1)
}

function ConvertTo-ConstantCase {
    param([string]$Name)
    # Convert camelCase/PascalCase to CONSTANT_CASE
    $result = $Name -creplace '([A-Z])', '_$1'
    $result = $result.TrimStart('_')
    return $result.ToUpper()
}

# Generic {Processor}Step skeleton — emitted for non-MT processors (and for any
# processor not already consumed by an MT Prepare/Save pair). The @StepName value
# is the FULL class name ("${Proc}Step"), matching the MT Prepare/Save convention
# so the runtime step name, the Java class, and the Designer block StepName are
# all identical (StepRegistry.getStep is case-sensitive).
function New-GenericStepJava {
    param([string]$Proc, [string]$Pkg)
    $stepName = "${Proc}Step"
    return @"
package $Pkg.steps;

import $Pkg.model.InitParameters;
import $Pkg.transaction.ProcessTransaction;
import by.a1.rpa.core.Step;
import by.a1.rpa.core.StepName;
import by.a1.rpa.core.transaction.Transaction;
import by.a1.rpa.orchestrator.OrchestratorService;
import by.a1.rpa.orchestrator.model.Asset;
import com.google.inject.Inject;
import java.util.List;
import java.util.Optional;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@StepName("$stepName")
public class $stepName implements Step {

  private final OrchestratorService orchestratorService;

  @Inject
  public $stepName(OrchestratorService orchestratorService) {
    this.orchestratorService = orchestratorService;
  }

  @Override
  public void execute(Transaction transaction, List<String> args) {
    String className = this.getClass().getSimpleName();
    log.info("Start {}.execute()", className);

    ProcessTransaction processTransaction = new ProcessTransaction(transaction);
    Optional<InitParameters> initParams = transaction.getInitParameters(InitParameters.class);
    InitParameters params = initParams.orElseThrow(
        () -> new IllegalStateException("InitParameters not found"));

    // TODO: Adapt business logic from WF ${Proc}Processor

    log.info("Finish {}.execute()", className);
  }
}
"@
}

# === DESIGNER VERSION CHECK ===
function Test-DesignerVersion {
    param([string]$RpaSuiteDir)

    $designerExe = "C:\Program Files\Sherpa RPA\Designer\DiagramDesigner.exe"
    $ok = $true

    # Check EXE version
    if (Test-Path $designerExe) {
        $installedExeVersion = (Get-Item $designerExe -ErrorAction SilentlyContinue).VersionInfo.FileVersion
        if ($installedExeVersion -and ($installedExeVersion -ne $script:ExpectedDesignerExeVersion)) {
            $report.errors += "Designer EXE version mismatch! Expected $($script:ExpectedDesignerExeVersion), found $installedExeVersion. STOP and update wf-migrate skill."
            Write-ReportItem "ERROR" "Designer EXE version mismatch! Expected $($script:ExpectedDesignerExeVersion), found $installedExeVersion" "Red"
            $ok = $false
        } else {
            Write-ReportItem "Designer EXE Version" "$installedExeVersion (OK)" "Green"
        }
    } else {
        $report.warnings += "Sherpa Designer not found at $designerExe. Cannot verify version."
        Write-ReportItem "Designer" "Not found — skipping version check" "Yellow"
    }

    # Check reference .sherpa ProductVersion (freshest merged-to-default-branch reference)
    if ($RpaSuiteDir -and (Test-Path $RpaSuiteDir)) {
        $refSherpas = Get-FreshestReferenceSherpa -RpaSuiteDir $RpaSuiteDir
        if ($refSherpas) {
            try {
                $refJson = Get-Content $refSherpas.FullName -Raw | ConvertFrom-Json
                if ($refJson.ProductVersion -and ($refJson.ProductVersion -ne $script:ExpectedProductVersion)) {
                    $report.warnings += "Reference .sherpa ProductVersion differs from expected (expected $($script:ExpectedProductVersion), found $($refJson.ProductVersion)). Non-blocking — .sherpa ProductVersion varies per project and is bumped by Designer."
                    Write-ReportItem "WARN" ".sherpa ProductVersion $($refJson.ProductVersion) (expected $($script:ExpectedProductVersion)) - non-blocking" "Yellow"
                } else {
                    Write-ReportItem "Reference .sherpa" "ProductVersion $($refJson.ProductVersion) (OK)" "Green"
                }
            } catch {
                $report.warnings += "Could not parse reference .sherpa for version check."
            }
        }
    }

    return $ok
}

# === FRESHEST REFERENCE .sherpa SELECTION ===
# Pick the freshest merged-to-default-branch reference .sherpa in rpa-suite.
# The master gate excludes feature-branch / WIP processes (freshness is recency, not quality);
# rpa-core canon wins over any sibling pattern. Falls back to first-found when git is
# unavailable or no process is present on the default branch, so generation never breaks.
function Get-FreshestReferenceSherpa {
  param([string]$RpaSuiteDir)
  if (-not $RpaSuiteDir -or -not (Test-Path $RpaSuiteDir)) { return $null }
  $sherpaFiles = @(Get-ChildItem -Path $RpaSuiteDir -Filter "*.sherpa" -Recurse -ErrorAction SilentlyContinue)
  if (-not $sherpaFiles) { return $null }

  # Default branch = origin/HEAD, falling back to master.
  $defaultBranch = 'master'
  try {
    $ref = & git -C $RpaSuiteDir rev-parse --abbrev-ref origin/HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $ref) {
      if ($ref -match '/') { $ref = ($ref -split '/')[-1] }
      $defaultBranch = $ref
    }
  } catch { }

  # Rank by last commit date on the default branch (master gate). %ci output is
  # lexicographically sortable (YYYY-MM-DD HH:MM:SS +ZZZZ), so string sort = chronological.
  $ranked = foreach ($f in $sherpaFiles) {
    $moduleDir = Split-Path $f.FullName -Parent
    $dateStr = ''
    try { $dateStr = (& git -C $RpaSuiteDir log -1 --format=%ci $defaultBranch -- $moduleDir 2>$null) } catch { }
    [pscustomobject]@{ File = $f; DateStr = $dateStr }
  }
  $onMaster = @($ranked | Where-Object { $_.DateStr } | Sort-Object DateStr -Descending)
  if ($onMaster) { return $onMaster[0].File }
  return $sherpaFiles[0]
}

# === SHERPA DESIGNER FILE GENERATION ===
# Removes the dangling Args="$TaskGuid" reference from Java Step blocks in diagrams
# that have no block assigning it (OrchGetDefaultTask/ReceiveRobotTask). The skeleton
# (gradle generateProcess) ships every Step block with Args="$TaskGuid"; in a non-MT
# diagram $TaskGuid is $null at runtime and the block wrapper's $Args.Replace(...)
# throws "You cannot call a method on a null-valued expression" ([UNHANDLED ERROR]).
function Repair-JavaStepArgs {
    param([string]$ProjectDir)

    foreach ($processFile in Get-ChildItem -Path $ProjectDir -Filter '*.process' -Recurse) {
        if ($processFile.FullName -match '\\\.backup\\') { continue }
        $content = Get-Content $processFile.FullName -Raw -Encoding UTF8
        if ($content -notmatch 'Value="\$TaskGuid"') { continue }
        # A receiver block assigns $script:TaskGuid, making the reference legitimate
        # (MT queue pattern). Anything else — a dangling reference to null.
        if ($content -match 'TaskGuid\s*=') {
            Write-ReportItem "Checked" "$($processFile.Name): queue receiver present, Args=`$TaskGuid kept" "Yellow"
            continue
        }
        $fixed = $content -replace 'Value="\$TaskGuid"', 'Value=""'
        Set-Content -Path $processFile.FullName -Value $fixed -Encoding UTF8
        Write-ReportItem "Repaired" "$($processFile.Name): cleared dangling Args=`$TaskGuid on Java Step blocks (no queue receiver in diagram)" "Yellow"
    }
}

function New-SherpaDesignerFiles {
    param(
        [string]$ProjectDir,
        [string]$ProjectName,
        [string]$PackageName,
        [string]$RpaSuiteDir,
        [string]$DesignerProjectName = "",
        [string[]]$StepNames = @(),
        [string]$InitParamsAsset     = "",
        [string]$EmailTemplatesAsset = "",
        [string]$StepArgs            = "",
        [switch]$hasMt,
        [array]$manualTasks = @(),
        [string]$mtQueueName = ""
    )

    # Designer files use the human-readable name (e.g. "ICS-NNNNN Обновление справочника")
    # If not provided, fall back to the technical project name.
    $designerName = if ($DesignerProjectName) { $DesignerProjectName } else { $ProjectName }

    Write-ReportHeader "Sherpa Designer Files"

    # Load reference .sherpa for metadata (freshest merged-to-default-branch reference)
    $refSherpa = $null
    if ($RpaSuiteDir -and (Test-Path $RpaSuiteDir)) {
        $refSherpas = Get-FreshestReferenceSherpa -RpaSuiteDir $RpaSuiteDir
        if ($refSherpas) { $refSherpa = $refSherpas.FullName }
    }

    $refJson = $null
    if ($refSherpa -and (Test-Path $refSherpa)) {
        try { $refJson = Get-Content $refSherpa -Raw | ConvertFrom-Json } catch {}
    }

    # Fallback metadata if no reference
    $productVersion = $script:ExpectedProductVersion
    $version        = if ($refJson.Version)        { $refJson.Version }        else { "1.00" }
    $isDarkTheme    = if ($refJson.IsDarkTheme -ne $null) { $refJson.IsDarkTheme } else { $true }

    $references = if ($refJson.References) { $refJson.References } else { @{ Items = @("Microsoft.CSharp","System","System.Core","System.Data","System.Data.DataSetExtensions","System.Deployment","System.IO","System.Linq","System.Net.Http","System.Text.Encoding","System.Web","System.Windows.Forms","System.Xml") } }
    $properties = if ($refJson.Properties) { $refJson.Properties } else {
        @{
            RobotName = ""
            RobotVersion = ""
            Description = ""
            AllowedRunWithoutConfirm = $false
            DisableVisibleInParams = $false
            DisableVisibleOutParams = $false
            TotalBlockExecutionDelay = 0
            InParams = @()
            OutParams = @()
            Settings = @()
            PythonModules = ""
            ModelAutopilot = ""
            ModelAIServer = ""
        }
    }

    # --- 1. Generate full .sherpa tree ---
    function Build-SherpaFolderJson($path) {
        $name = Split-Path $path -Leaf
        $folders = @()
        $files   = @()
        foreach ($dir in Get-ChildItem -Path $path -Directory) {
            if ($dir.Name -in '.git','build','.backup','.gradle','out','bin','target') { continue }
            $folders += (Build-SherpaFolderJson -path $dir.FullName)
        }
        foreach ($file in Get-ChildItem -Path $path -File) {
            if ($file.Name -eq "$designerName.sherpa") { continue }
            if ($file.Name -eq "$designerName.sherpax") { continue }
            $isMain = $file.Name -eq 'Главная.process'
            $files += @{
                RelativePath = $file.Name
                Main         = $isMain
                Showing      = $isMain
                Pinned       = $false
            }
        }
        return @{
            RelativePath = $name
            Folders      = $folders
            Files        = $files
            Links        = @()
        }
    }

    $rootFolder = @{
        RelativePath = ''
        Folders      = @()
        Files        = @()
        Links        = @()
    }
    foreach ($item in Get-ChildItem -Path $ProjectDir) {
        if ($item.Name -in '.git','build','.backup','.gradle','out','bin','target') { continue }
        if ($item.Name -eq "$designerName.sherpa") { continue }
        if ($item.Name -eq "$designerName.sherpax") { continue }
        if ($item.PSIsContainer) {
            $rootFolder.Folders += (Build-SherpaFolderJson -path $item.FullName)
        } else {
            $isMain = $item.Name -eq 'Главная.process'
            $rootFolder.Files += @{
                RelativePath = $item.Name
                Main         = $isMain
                Showing      = $isMain
                Pinned       = $false
            }
        }
    }

    $sherpaObj = @{
        Version        = $version
        IsDarkTheme    = $isDarkTheme
        ProductVersion = $productVersion
        References     = $references
        Properties     = $properties
        Folders        = @($rootFolder)
        Files          = @()
        Links          = @()
    }

    $sherpaJson = $sherpaObj | ConvertTo-Json -Depth 100
    # Fix Unicode escapes (PowerShell 5.1 escapes non-ASCII)
    $sherpaJson = [regex]::Replace($sherpaJson, '\\u([0-9a-fA-F]{4})', {
        param($match)
        [char]::ConvertFromUtf32([Convert]::ToInt32($match.Groups[1].Value, 16))
    })
    $sherpaPath = Join-Path $ProjectDir "$designerName.sherpa"
    $sherpaJson | Set-Content -Path $sherpaPath -Encoding UTF8
    Write-ReportItem "Generated" "$designerName.sherpa (full tree)" "Green"

    # --- 2. Generate .sherpax ---
    $sherpaxObj = @{
        Version = $version
        ActiveProjectRelativePath = "$designerName.sherpa"
        Projects = @(@{ RelativePath = "$designerName.sherpa" })
    }
    $sherpaxPath = Join-Path $ProjectDir "$designerName.sherpax"
    $sherpaxObj | ConvertTo-Json -Depth 10 | Set-Content -Path $sherpaxPath -Encoding UTF8
    Write-ReportItem "Generated" "$designerName.sherpax" "Green"

    # --- 3. Generate Главная.process ---
    $mainProcessPath = Join-Path $ProjectDir "Главная.process"
    Build-DesignerProcessFile -Path $mainProcessPath -StepNames $StepNames `
        -InitParamsAsset $InitParamsAsset `
        -EmailTemplatesAsset $EmailTemplatesAsset `
        -StepArgs $StepArgs `
        -hasMt:$hasMt `
        -manualTasks:$manualTasks `
        -mtQueueName:$mtQueueName
    if ($hasMt -and $manualTasks.Count -gt 0) {
        Write-ReportItem "Generated" "Главная.process (Start + $($manualTasks.Count) Prepare + ReceiveRobotTask + Switch/Case + $($manualTasks.Count) Save + End)" "Green"
    } else {
        Write-ReportItem "Generated" "Главная.process (Start + Try/Catch + $($StepNames.Count) Steps + HandleError + Прервать + End)" "Green"
    }

    # --- 4. Clear skeleton-inherited Args="$TaskGuid" on Java Step blocks ---
    Repair-JavaStepArgs -ProjectDir $ProjectDir
}

# --- Process file builder (uses external block templates) ---
function Build-DesignerProcessFile {
    param(
        [string]$Path,
        [string[]]$StepNames = @(),
        [string]$InitParamsAsset     = "",
        [string]$EmailTemplatesAsset = "",
        [string]$StepArgs            = "",
        [switch]$hasMt,
        [array]$manualTasks = @(),
        [string]$mtQueueName = ""
    )

    $scriptDir = $PSScriptRoot
    $stepTemplate = Get-Content "$scriptDir\step_block_template.txt" -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    $endTemplate  = Get-Content "$scriptDir\end_block_template.txt"  -Encoding UTF8 -Raw -ErrorAction SilentlyContinue

    if (-not $stepTemplate) {
        throw "step_block_template.txt not found in $scriptDir. Update wf-migrate skill."
    }
    if (-not $endTemplate) {
        throw "end_block_template.txt not found in $scriptDir. Update wf-migrate skill."
    }

    # Non-MT canonical diagram templates — Try/Catch, HandleError, Прервать.
    # Loaded unconditionally (like $endTemplate); only the non-MT branch emits them.
    $tryCatchTemplate   = Get-Content "$scriptDir\trycatch_block_template.txt"   -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    $handleErrorTemplate = Get-Content "$scriptDir\handleerror_block_template.txt" -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    $fullAbortTemplate  = Get-Content "$scriptDir\fullabort_block_template.txt"  -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
    if (-not $tryCatchTemplate) {
        throw "trycatch_block_template.txt not found in $scriptDir. Update wf-migrate skill."
    }
    if (-not $handleErrorTemplate) {
        throw "handleerror_block_template.txt not found in $scriptDir. Update wf-migrate skill."
    }
    if (-not $fullAbortTemplate) {
        throw "fullabort_block_template.txt not found in $scriptDir. Update wf-migrate skill."
    }

    # MT diagram templates — loaded only when MT detected.
    $receiveTemplate = $null
    $switchTemplate  = $null
    if ($hasMt) {
        $receiveTemplate = Get-Content "$scriptDir\receive_robot_task_block_template.txt" -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
        $switchTemplate  = Get-Content "$scriptDir\switch_case_block_template.txt"  -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
        if (-not $receiveTemplate) {
            throw "receive_robot_task_block_template.txt not found in $scriptDir. Update wf-migrate skill."
        }
        if (-not $switchTemplate) {
            throw "switch_case_block_template.txt not found in $scriptDir. Update wf-migrate skill."
        }
    }

    # Connection XML helper (used by the MT branch; the flat branch keeps its inline
    # here-strings untouched so non-MT output stays byte-identical).
    function New-Conn([string]$Src, [string]$Sink, [string]$SrcConn, [string]$SinkConn, [int]$Z) {
        @"
    <Connection>
      <SourceID>$Src</SourceID>
      <SinkID>$Sink</SinkID>
      <SourceConnectorName>$SrcConn</SourceConnectorName>
      <SinkConnectorName>$SinkConn</SinkConnectorName>
      <SourceArrowSymbol>None</SourceArrowSymbol>
      <SinkArrowSymbol>Arrow</SinkArrowSymbol>
      <zIndex>$Z</zIndex>
    </Connection>
"@
    }

    $startId = 'a49d986b-3034-4b63-bd72-11a826c70871'
    $endId   = [guid]::NewGuid().ToString()

    # Build Start block
    $startBlock = @'
    <DesignerItem>
      <Left>700</Left>
      <Top>700</Top>
      <Width>70</Width>
      <Height>70</Height>
      <ID>$startId</ID>
      <zIndex>0</zIndex>
      <IsGroup>false</IsGroup>
      <IsEnabled>true</IsEnabled>
      <Description></Description>
      <IsPSVerified>true</IsPSVerified>
      <ParentID>00000000-0000-0000-0000-000000000000</ParentID>
      <StorageSelectors></StorageSelectors>
      <Content>&lt;ToolboxItemSettings DisplayName="Старт" InternalName="Start" FriendlyName="С блока Старт начинается работа диаграммы. В диаграмме может быть только один такой блок." Width="70" Height="70" PathToImage="ExternalToolboxes\Image\ico_Process Start.png" PathToToolboxImage="ExternalToolboxes\Image\icotb_Process Start.png" ImageType="OnlyImage" NoDelete="False" Invisible="False" Proportional="True" Version="10" LinuxAvailable="True" Code="&amp;#xA;function Start{{{block_id}}}&amp;#xA;{                  &amp;#xA;    try&amp;#xA;    {&amp;#xA;    $currentblockid = &amp;quot;{{{block_native_id}}}&amp;quot;;   &amp;#xA;    &amp;#xA;        $Value        = {{{Value}}};&amp;#xA;        $SendOrkest   = ${{{SendOrkest}}};&amp;#xA;        $IsScreenshot = ${{{IsScreenshot}}};&amp;#xA;        &amp;#xA;        $ValueStr = VarToString($Value); &amp;#xA;             &amp;#xA;        $val = _shield $ValueStr;&amp;#xA;        if($SendOrkest -or $IsScreenshot)&amp;#xA;        {                      &amp;#xA;            if($val.Length -eq 0)&amp;#xA;            {&amp;#xA;                $val = &amp;quot;Screenshot &amp;quot;+[DateTime]::Now.ToString();&amp;#xA;            }&amp;#xA;            Write-Host(&amp;quot;&amp;lt;block&amp;gt;&amp;lt;ID&amp;gt;{{{block_native_id}}}&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;SendLogOrkest&amp;lt;/InternalName&amp;gt;&amp;lt;UITextValue&amp;gt;$val&amp;lt;/UITextValue&amp;gt;&amp;lt;UITextType&amp;gt;Info&amp;lt;/UITextType&amp;gt;&amp;lt;IsScreenshot&amp;gt;{{{IsScreenshot}}}&amp;lt;/IsScreenshot&amp;gt;&amp;lt;/block&amp;gt;&amp;quot;); &amp;#xA;        }&amp;#xA;        if($val.Length -gt 0)&amp;#xA;        {&amp;#xA;            $xmlvar = &amp;quot;&amp;quot;;&amp;#xA;            try&amp;#xA;            {&amp;#xA;                $xmlvar = $script:__BinFormatter.vartoxmlraw($Value);&amp;#xA;            }&amp;#xA;            catch{} &amp;#xA;            Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;{{{block_native_id}}}&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;Log&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$val&amp;lt;/InternalValue&amp;gt;$xmlvar&amp;lt;/info&amp;gt;&amp;quot;);&amp;#xA;        }&amp;#xA;    }&amp;#xA;    catch &amp;#xA;    { &amp;#xA;    }&amp;#xA;    &amp;#xA;    try&amp;#xA;    {&amp;#xA;&amp;#xA;            try&amp;#xA;            {         &amp;#xA;                {{{Variable1}}} = {{{Expression1}}};&amp;#xA;            }&amp;#xA;            catch { $errormessage = &amp;quot;Variable1: &amp;quot; + $_.Exception.Message; Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;$currentblockid&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;ErrorBlockLight&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$errormessage&amp;lt;/InternalValue&amp;gt;&amp;lt;/info&amp;gt;&amp;quot;); }&amp;#xA;&amp;#xA;            try&amp;#xA;            {         &amp;#xA;                {{{Variable2}}} = {{{Expression2}}};&amp;#xA;            }&amp;#xA;            catch { $errormessage = &amp;quot;Variable2: &amp;quot; + $_.Exception.Message; Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;$currentblockid&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;ErrorBlockLight&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$errormessage&amp;lt;/InternalValue&amp;gt;&amp;lt;/info&amp;gt;&amp;quot;); }&amp;#xA;&amp;#xA;            try&amp;#xA;            {         &amp;#xA;                {{{Variable3}}} = {{{Expression3}}};&amp;#xA;            }&amp;#xA;            catch { $errormessage = &amp;quot;Variable3: &amp;quot; + $_.Exception.Message; Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;$currentblockid&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;ErrorBlockLight&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$errormessage&amp;lt;/InternalValue&amp;gt;&amp;lt;/info&amp;gt;&amp;quot;); }&amp;#xA;&amp;#xA;            try&amp;#xA;            {         &amp;#xA;                {{{Variable4}}} = {{{Expression4}}};&amp;#xA;            }&amp;#xA;            catch { $errormessage = &amp;quot;Variable4: &amp;quot; + $_.Exception.Message; Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;$currentblockid&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;ErrorBlockLight&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$errormessage&amp;lt;/InternalValue&amp;gt;&amp;lt;/info&amp;gt;&amp;quot;); }&amp;#xA;&amp;#xA;            try&amp;#xA;            {         &amp;#xA;                {{{Variable5}}} = {{{Expression5}}};&amp;#xA;            }&amp;#xA;            catch { $errormessage = &amp;quot;Variable5: &amp;quot; + $_.Exception.Message; Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;$currentblockid&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;ErrorBlockLight&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$errormessage&amp;lt;/InternalValue&amp;gt;&amp;lt;/info&amp;gt;&amp;quot;); }&amp;#xA;&amp;#xA;        try&amp;#xA;        {         &amp;#xA;            {{{Expression6}}}&amp;#xA;        }&amp;#xA;        catch { $errormessage = &amp;quot;Expression6: &amp;quot; + $_.Exception.Message; Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;$currentblockid&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;ErrorBlockLight&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$errormessage&amp;lt;/InternalValue&amp;gt;&amp;lt;/info&amp;gt;&amp;quot;); }&amp;#xA;        try&amp;#xA;        {         &amp;#xA;            {{{Expression7}}}&amp;#xA;        }&amp;#xA;        catch { $errormessage = &amp;quot;Expression7: &amp;quot; + $_.Exception.Message; Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;$currentblockid&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;ErrorBlockLight&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$errormessage&amp;lt;/InternalValue&amp;gt;&amp;lt;/info&amp;gt;&amp;quot;); }&amp;#xA;        try&amp;#xA;        {         &amp;#xA;            {{{Expression8}}}&amp;#xA;        }&amp;#xA;        catch { $errormessage = &amp;quot;Expression8: &amp;quot; + $_.Exception.Message; Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;$currentblockid&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;ErrorBlockLight&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$errormessage&amp;lt;/InternalValue&amp;gt;&amp;lt;/info&amp;gt;&amp;quot;); }&amp;#xA;        try&amp;#xA;        {         &amp;#xA;            {{{Expression9}}}&amp;#xA;        }&amp;#xA;        catch { $errormessage = &amp;quot;Expression9: &amp;quot; + $_.Exception.Message; Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;$currentblockid&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;ErrorBlockLight&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$errormessage&amp;lt;/InternalValue&amp;gt;&amp;lt;/info&amp;gt;&amp;quot;); }&amp;#xA;        try&amp;#xA;        {         &amp;#xA;            {{{Expression10}}}&amp;#xA;        }&amp;#xA;        catch { $errormessage = &amp;quot;Expression10: &amp;quot; + $_.Exception.Message; Write-Host(&amp;quot;&amp;lt;info&amp;gt;&amp;lt;ID&amp;gt;$currentblockid&amp;lt;/ID&amp;gt;&amp;lt;InternalName&amp;gt;ErrorBlockLight&amp;lt;/InternalName&amp;gt;&amp;lt;InternalValue&amp;gt;$errormessage&amp;lt;/InternalValue&amp;gt;&amp;lt;/info&amp;gt;&amp;quot;); }&amp;#xA;        &amp;#xA;    }&amp;#xA;    catch {}&amp;#xA;    &amp;#xA;    $__Error.Enter(&amp;quot;{{{block_native_id}}}&amp;quot;, &amp;quot;{{{ErrorLevel}}}&amp;quot;,&amp;quot;{{{ErrorDirection}}}&amp;quot;,&amp;quot;{{{ReportLevel}}}&amp;quot;,&amp;quot;{{{ErrorMessage}}}&amp;quot;);&amp;#xA;    &amp;#xA;    $script:__NextBlockID = &amp;quot;{{{connector-Next}}}&amp;quot;;&amp;#xA;}                   &amp;#xA;                " ProtoName="" TextColor="#FFDADADA" Language="" UrlVideo="{x:Null}" DerivedFrom="" NoResize="False" Container="False" MouseOverColor="Gray" MouseOverFill="Transparent" IsExpressionOnPause="False" ExpressionOnPause="" IsCollapsedBlock="False" Breakpoint="False" DirivedFrom="" xmlns="clr-namespace:ToolboxDesigner.Core;assembly=DiagramDesigner" xmlns:av="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:s="clr-namespace:System;assembly=mscorlib" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"&gt;&lt;ToolboxItemSettings.PathStyle&gt;&lt;av:Style TargetType="av:Path"&gt;&lt;av:Style.BasedOn&gt;&lt;av:Style TargetType="av:Path"&gt;&lt;av:Style.Resources&gt;&lt;av:ResourceDictionary /&gt;&lt;/av:Style.Resources&gt;&lt;av:Setter Property="av:Shape.Fill"&gt;&lt;av:Setter.Value&gt;&lt;av:SolidColorBrush&gt;#FF252525&lt;/av:SolidColorBrush&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:Shape.Stroke"&gt;&lt;av:Setter.Value&gt;&lt;av:SolidColorBrush&gt;#FF41B1E1&lt;/av:SolidColorBrush&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:Shape.StrokeThickness"&gt;&lt;av:Setter.Value&gt;&lt;s:Double&gt;2&lt;/s:Double&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:Shape.StrokeLineJoin"&gt;&lt;av:Setter.Value&gt;&lt;x:Static Member="av:PenLineJoin.Round" /&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:Shape.Stretch"&gt;&lt;av:Setter.Value&gt;&lt;x:Static Member="av:Stretch.Fill" /&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:UIElement.IsHitTestVisible"&gt;&lt;av:Setter.Value&gt;&lt;s:Boolean&gt;False&lt;/s:Boolean&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:UIElement.SnapsToDevicePixels"&gt;&lt;av:Setter.Value&gt;&lt;s:Boolean&gt;True&lt;/s:Boolean&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;/av:Style&gt;&lt;/av:Style.BasedOn&gt;&lt;av:Style.Resources&gt;&lt;av:ResourceDictionary /&gt;&lt;/av:Style.Resources&gt;&lt;av:Setter Property="av:Path.Data"&gt;&lt;av:Setter.Value&gt;&lt;av:StreamGeometry&gt;M75,50C75,63.8071187457698 63.8071187457698,75 50,75 36.1928812542302,75 25,63.8071187457698 25,50 25,36.1928812542302 36.1928812542302,25 50,25 63.8071187457698,25 75,36.1928812542302 75,50z&lt;/av:StreamGeometry&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;/av:Style&gt;&lt;/ToolboxItemSettings.PathStyle&gt;&lt;ToolboxItemSettings.PathStyle_DragThumb&gt;&lt;av:Style TargetType="av:Path"&gt;&lt;av:Style.BasedOn&gt;&lt;av:Style TargetType="av:Path"&gt;&lt;av:Style.BasedOn&gt;&lt;av:Style TargetType="av:Path"&gt;&lt;av:Style.Resources&gt;&lt;av:ResourceDictionary /&gt;&lt;/av:Style.Resources&gt;&lt;av:Setter Property="av:Shape.Fill"&gt;&lt;av:Setter.Value&gt;&lt;av:SolidColorBrush&gt;#FFFFFFFF&lt;/av:SolidColorBrush&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:Shape.Stroke"&gt;&lt;av:Setter.Value&gt;&lt;av:SolidColorBrush&gt;#FF41B1E1&lt;/av:SolidColorBrush&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:Shape.StrokeThickness"&gt;&lt;av:Setter.Value&gt;&lt;s:Double&gt;2&lt;/s:Double&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:Shape.StrokeLineJoin"&gt;&lt;av:Setter.Value&gt;&lt;x:Static Member="av:PenLineJoin.Round" /&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:Shape.Stretch"&gt;&lt;av:Setter.Value&gt;&lt;x:Static Member="av:Stretch.Fill" /&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:UIElement.IsHitTestVisible"&gt;&lt;av:Setter.Value&gt;&lt;s:Boolean&gt;False&lt;/s:Boolean&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:UIElement.SnapsToDevicePixels"&gt;&lt;av:Setter.Value&gt;&lt;s:Boolean&gt;True&lt;/s:Boolean&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;/av:Style&gt;&lt;/av:Style.BasedOn&gt;&lt;av:Style.Resources&gt;&lt;av:ResourceDictionary /&gt;&lt;/av:Style.Resources&gt;&lt;av:Setter Property="av:Path.Data"&gt;&lt;av:Setter.Value&gt;&lt;av:StreamGeometry&gt;M75,50C75,63.8071187457698 63.8071187457698,75 50,75 36.1928812542302,75 25,63.8071187457698 25,50 25,36.1928812542302 36.1928812542302,25 50,25 63.8071187457698,25 75,36.1928812542302 75,50z&lt;/av:StreamGeometry&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;/av:Style&gt;&lt;/av:Style.BasedOn&gt;&lt;av:Style.Resources&gt;&lt;av:ResourceDictionary /&gt;&lt;/av:Style.Resources&gt;&lt;av:Setter Property="av:UIElement.IsHitTestVisible"&gt;&lt;av:Setter.Value&gt;&lt;s:Boolean&gt;True&lt;/s:Boolean&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:Shape.Fill"&gt;&lt;av:Setter.Value&gt;&lt;av:SolidColorBrush&gt;#00FFFFFF&lt;/av:SolidColorBrush&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;av:Setter Property="av:Shape.Stroke"&gt;&lt;av:Setter.Value&gt;&lt;av:SolidColorBrush&gt;#00FFFFFF&lt;/av:SolidColorBrush&gt;&lt;/av:Setter.Value&gt;&lt;/av:Setter&gt;&lt;/av:Style&gt;&lt;/ToolboxItemSettings.PathStyle_DragThumb&gt;&lt;ToolboxItemSettings.Properties&gt;&lt;PropertiesCollection Capacity="32"&gt;&lt;Property Name="Value" Tooltip="[Любой тип данных] Числовая, текстовая константа (в кавычках), имя переменной (начинающееся с $) или любое выражение, значение которого будет выведено в лог в процессе работы сценария робота. Значение может в том числе иметь сложный тип данных, например Список, Таблица или Словарь." CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="&amp;quot;&amp;quot;" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Записать в лог" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Variable1" Tooltip="[Переменная] Имя первой переменной, которой необходимо присвоить новое значение. Можно выбрать из выпадающего списка переменную, которая была ранее объявлена в панели Переменные, а также ввести имя новой или использовавшейся ранее в другом блоке переменной, даже если она не была объявлена в панели Переменные." CatalogName="Main properties" Type="Variable" Value="" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Переменная 1" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Expression1" Tooltip="[Любой тип данных] Новое значение первой переменной. Свойство игнорируется, если не задано имя первой переменной. Новое значение переменной может быть как константой (числом, текстовой строкой), так и выражением с использованием других переменных и/или функций. В новом значении переменной разрешено использовать выражение с участием этой же переменной. Не забудьте, что здесь и в других блоках используемые в выражениях названия переменных должны начинаться с символа $, а строковые константы должны заключаться в кавычки." CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="&amp;quot;&amp;quot;" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Значение 1" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Variable2" Tooltip="[Переменная] Имя второй переменной, которой необходимо присвоить новое значение. Можно выбрать из выпадающего списка переменную, которая была ранее объявлена в панели Переменные, а также ввести имя новой или использовавшейся ранее в другом блоке переменной, даже если она не была объявлена в панели Переменные." CatalogName="Main properties" Type="Variable" Value="" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Переменная 2" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Expression2" Tooltip="[Любой тип данных] Новое значение второй переменной. Свойство игнорируется, если не задано имя второй переменной. Новое значение переменной может быть как константой (числом, текстовой строкой), так и выражением с использованием других переменных и/или функций. В новом значении переменной разрешено использовать выражение с участием этой же переменной. Не забудьте, что здесь и в других блоках используемые в выражениях названия переменных должны начинаться с символа $, а строковые константы должны заключаться в кавычки." CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="&amp;quot;&amp;quot;" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Значение 2" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Variable3" Tooltip="[Переменная] Имя третьей переменной, которой необходимо присвоить новое значение. Можно выбрать из выпадающего списка переменную, которая была ранее объявлена в панели Переменные, а также ввести имя новой или использовавшейся ранее в другом блоке переменной, даже если она не была объявлена в панели Переменные." CatalogName="Main properties" Type="Variable" Value="" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Переменная 3" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Expression3" Tooltip="[Любой тип данных] Новое значение третьей переменной. Свойство игнорируется, если не задано имя третьей переменной. Новое значение переменной может быть как константой (числом, текстовой строкой), так и выражением с использованием других переменных и/или функций. В новом значении переменной разрешено использовать выражение с участием этой же переменной. Не забудьте, что здесь и в других блоках используемые в выражениях названия переменных должны начинаться с символа $, а строковые константы должны заключаться в кавычки." CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="&amp;quot;&amp;quot;" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Значение 3" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Variable4" Tooltip="[Переменная] Имя четвертой переменной, которой необходимо присвоить новое значение. Можно выбрать из выпадающего списка переменную, которая была ранее объявлена в панели Переменные, а также ввести имя новой или использовавшейся ранее в другом блоке переменной, даже если она не была объявлена в панели Переменные." CatalogName="Main properties" Type="Variable" Value="" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Переменная 4" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Expression4" Tooltip="[Любой тип данных] Новое значение четвертой переменной. Свойство игнорируется, если не задано имя первой переменной. Новое значение переменной может быть как константой (числом, текстовой строкой), так и выражением с использованием других переменных и/или функций. В новом значении переменной разрешено использовать выражение с участием этой же переменной. Не забудьте, что здесь и в других блоках используемые в выражениях названия переменных должны начинаться с символа $, а строковые константы должны заключаться в кавычки." CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="&amp;quot;&amp;quot;" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Значение 4" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Variable5" Tooltip="[Переменная] Имя пятой переменной, которой необходимо присвоить новое значение. Можно выбрать из выпадающего списка переменную, которая была ранее объявлена в панели Переменные, а также ввести имя новой или использовавшейся ранее в другом блоке переменной, даже если она не была объявлена в панели Переменные." CatalogName="Main properties" Type="Variable" Value="" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Переменная 5" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Expression5" Tooltip="[Любой тип данных] Новое значение пятой переменной. Свойство игнорируется, если не задано имя первой переменной. Новое значение переменной может быть как константой (числом, текстовой строкой), так и выражением с использованием других переменных и/или функций. В новом значении переменной разрешено использовать выражение с участием этой же переменной. Не забудьте, что здесь и в других блоках используемые в выражениях названия переменных должны начинаться с символа $, а строковые константы должны заключаться в кавычки." CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="&amp;quot;&amp;quot;" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Значение 5" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Expression6" Tooltip="[Выражение] Выражение, которое необходимо выполнить. Должно быть записано в формате языка PowerShell" CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Выражение 1" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Expression7" Tooltip="[Выражение] Выражение, которое необходимо выполнить. Должно быть записано в формате языка PowerShell" CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Выражение 2" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Expression8" Tooltip="[Выражение] Выражение, которое необходимо выполнить. Должно быть записано в формате языка PowerShell" CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Выражение 3" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Expression9" Tooltip="[Выражение] Выражение, которое необходимо выполнить. Должно быть записано в формате языка PowerShell" CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Выражение 4" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="Expression10" Tooltip="[Выражение] Выражение, которое необходимо выполнить. Должно быть записано в формате языка PowerShell" CatalogName="Main properties" Type="Expression" Value="" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="{x:Null}" Caption="Выражение 5" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="SendOrkest" Tooltip="Если выбрано, то текст будет также логироваться в оркестратор, если подключение к нему активно" CatalogName="Main properties" Type="Bool" Value="False" Visible="True" DefaultValue="&amp;quot;&amp;quot;" ValueType="{x:Null}" EnumVariants="" Caption="Логировать в оркестратор" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="IsScreenshot" Tooltip="Если выбрано, то будет создан скриншот экрана и отправлен в оркестратор, если подключение к нему активно" CatalogName="Main properties" Type="Bool" Value="False" Visible="True" DefaultValue="&amp;quot;&amp;quot;" ValueType="{x:Null}" EnumVariants="" Caption="Скриншот в оркестратор" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="ErrorLevel" Tooltip="Выбор уровня обработки ошибок. Возможные значения: &amp;quot;Default&amp;quot; - по умолчанию; &amp;quot;Ignore&amp;quot; - ошибки игнорируются; &amp;quot;Handle&amp;quot; - ошибки обрабатываются. Если выбрано значение &amp;quot;Default&amp;quot;, то, если это главная диаграмма, будет использоваться значение &amp;quot;Handle&amp;quot;, иначе будет использоваться значение блока &amp;quot;Старт&amp;quot; главной диаграммы" CatalogName="Error processing" Type="Enum" Value="Default" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="Default;Ignore;Handle" Caption="Уровень обработки" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="ErrorDirection" Tooltip="Выбор направления выхода из блока при возникновении ошибки. Возможные значения: &amp;quot;Default&amp;quot; - по умолчанию; &amp;quot;Right&amp;quot; - направо; &amp;quot;Bottom&amp;quot; - вниз. Данное свойство позволяет определить направление выхода при возникновении ошибок для блоков не содержащих коннектора &amp;quot;Если ошибка&amp;quot; (например блок &amp;quot;Условие&amp;quot;). Если выбрано значение &amp;quot;Default&amp;quot;, то, если это главная диаграмма, будет использоваться значение &amp;quot;Bottom&amp;quot;, иначе будет использоваться значение блока &amp;quot;Старт&amp;quot; главной диаграммы" CatalogName="Error processing" Type="Enum" Value="Default" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="Default;Right;Bottom" Caption="Направление выхода" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;Property Name="ReportLevel" Tooltip="Выбор уровня сообщений, которые будут выводить блоки при работе. Возможные значения: &amp;quot;Default&amp;quot; - по умолчанию; &amp;quot;Release&amp;quot; - вывод отключен; &amp;quot;Debug&amp;quot; - вывод основной информации; &amp;quot;Detailed&amp;quot; - вывод подробной информации. Если выбрано значение &amp;quot;Default&amp;quot;, то, если это главная диаграмма, будет использоваться значение &amp;quot;Debug&amp;quot;, иначе будет использоваться значение блока &amp;quot;Старт&amp;quot; главной диаграммы" CatalogName="Error processing" Type="Enum" Value="Default" Visible="True" DefaultValue="" ValueType="{x:Null}" EnumVariants="Default;Release;Debug;Detailed;Output" Caption="Уровень сообщений" ProtoName="" ReadOnly="False" IsRequired="False" IsPSVerified="True" /&gt;&lt;/PropertiesCollection&gt;&lt;/ToolboxItemSettings.Properties&gt;&lt;ToolboxItemSettings.ConnectorsSettings&gt;&lt;ConnectorsSettingsCollection Capacity="4"&gt;&lt;ConnectorSettings Name="Next" Orientation="Bottom" RelativePosition="0.5,1" MaxInConnections="0" MaxOutConnections="1" Color="#FF000000" Caption="{x:Null}" /&gt;&lt;/ConnectorsSettingsCollection&gt;&lt;/ToolboxItemSettings.ConnectorsSettings&gt;&lt;/ToolboxItemSettings&gt;</Content>
    </DesignerItem>
'@
    $startBlock = $startBlock.Replace('$startId', $startId)

    # === Block + connection building: flat (non-MT) or MT diagram ===
    $zIndex = 1
    $stepBlocks = @()
    $connections = @()
    $connZIndex = 0
    $endTop = 900

    if (-not $hasMt) {
        # --- canonical non-MT diagram ---
        # Main column: Start -> Try/Catch --Next-> Step₁ -> … -> Stepₙ -> Конец
        # Error branch: Try/Catch --Error-> HandleError --Next-> Прервать
        # No queue block (OrchGetDefaultTask/ReceiveRobotTask) — those are MT-only.
        $tryCatchId   = [guid]::NewGuid().ToString()
        $handleErrorId = [guid]::NewGuid().ToString()
        $abortId       = [guid]::NewGuid().ToString()

        # Try/Catch block — main column, directly below Start.
        $stepBlocks += @"
    <DesignerItem>
      <Left>705</Left>
      <Top>820</Top>
      <Width>200</Width>
      <Height>75</Height>
      <ID>$tryCatchId</ID>
      <zIndex>$zIndex</zIndex>
      <IsGroup>false</IsGroup>
      <IsEnabled>true</IsEnabled>
      <Description></Description>
      <IsPSVerified>true</IsPSVerified>
      <ParentID>00000000-0000-0000-0000-000000000000</ParentID>
      <StorageSelectors></StorageSelectors>
      <Content>$tryCatchTemplate</Content>
    </DesignerItem>
"@
        $zIndex++

        # Business Step blocks (reuse the step template; SaveTransaction=True only
        # on the first step, flipped to False on every later block).
        $steps = @()
        $top = 945
        foreach ($name in $StepNames) {
            # Diagram StepName property must equal the Java step's runtime name, which
            # is the @StepName value. New-GenericStepJava emits @StepName("${Proc}Step")
            # — the full class name — and $name here is that same class. So both the
            # diagram StepName and DisplayName equal $name (StepRegistry.getStep is
            # case-sensitive).
            $steps += @{ ID = [guid]::NewGuid().ToString(); Name = $name; StepName = $name; Top = $top }
            $top += 200
        }
        $stepIndex = 0
        foreach ($step in $steps) {
            $content = $stepTemplate
            $content = $content -replace 'DisplayName="initOrder"', "DisplayName=`"$($step.Name)`""
            $content = $content -replace 'Value="&amp;quot;initOrder&amp;quot;"', "Value=`"&amp;quot;$($step.StepName)&amp;quot;`""
            $content = $content -replace 'Value="&amp;quot;demo_init_params&amp;quot;"', "Value=`"&amp;quot;$InitParamsAsset&amp;quot;`""
            $content = $content -replace 'Value="&amp;quot;demo_email_templates&amp;quot;"', "Value=`"&amp;quot;$EmailTemplatesAsset&amp;quot;`""
            $content = $content -replace 'Value="&amp;quot;ТЕСТ&amp;quot;"', "Value=`"&amp;quot;$StepArgs&amp;quot;`""
            # SaveTransaction (Сохранение транзакции) — only on the first step.
            # Each SaveTransaction=True step calls StorageCreateFile under the same
            # transaction_<JobGuid> name, producing duplicate Storage records that
            # break StorageReadFile ("Found more than 1 record"). The first step
            # keeps the template default (True); every subsequent step is flipped
            # to False. Scoped to the SaveTransaction property only — Resume also
            # has Value="True" and must not be touched.
            if ($stepIndex -gt 0) {
                $content = $content -replace '(&lt;Property Name="SaveTransaction"[^/]*?Value=")True"', '$1False"'
                $content = $content -replace '(&lt;Property Name="SaveTransaction"[^/]*?DefaultValue=")True"', '$1False"'
            }
            $stepBlocks += @"
    <DesignerItem>
      <Left>705</Left>
      <Top>$($step.Top)</Top>
      <Width>200</Width>
      <Height>75</Height>
      <ID>$($step.ID)</ID>
      <zIndex>$zIndex</zIndex>
      <IsGroup>false</IsGroup>
      <IsEnabled>true</IsEnabled>
      <Description></Description>
      <IsPSVerified>true</IsPSVerified>
      <ParentID>00000000-0000-0000-0000-000000000000</ParentID>
      <StorageSelectors></StorageSelectors>
      <Content>$content</Content>
    </DesignerItem>
"@
            $zIndex++
            $stepIndex++
        }

        # HandleError block — error branch, right of the main column. The skeleton
        # template ships with mismatched placeholder asset names (InitParamsAssetName
        # -> "..._email_templates", EmailTemplatesAssetName -> "..._init_params");
        # substitute both by Property Name so they reference the process's actual
        # init-params / email-templates orchestrator assets.
        $heContent = $handleErrorTemplate
        $heContent = $heContent -replace '(&lt;Property Name="InitParamsAssetName"[^/]*?Value=")[^"]*"', "`$1&amp;quot;$InitParamsAsset&amp;quot;`""
        $heContent = $heContent -replace '(&lt;Property Name="EmailTemplatesAssetName"[^/]*?Value=")[^"]*"', "`$1&amp;quot;$EmailTemplatesAsset&amp;quot;`""
        $stepBlocks += @"
    <DesignerItem>
      <Left>1025</Left>
      <Top>950</Top>
      <Width>200</Width>
      <Height>75</Height>
      <ID>$handleErrorId</ID>
      <zIndex>$zIndex</zIndex>
      <IsGroup>false</IsGroup>
      <IsEnabled>true</IsEnabled>
      <Description></Description>
      <IsPSVerified>true</IsPSVerified>
      <ParentID>00000000-0000-0000-0000-000000000000</ParentID>
      <StorageSelectors></StorageSelectors>
      <Content>$heContent</Content>
    </DesignerItem>
"@
        $zIndex++

        # Прервать block — below HandleError, on the error branch.
        $stepBlocks += @"
    <DesignerItem>
      <Left>1090</Left>
      <Top>1150</Top>
      <Width>70</Width>
      <Height>70</Height>
      <ID>$abortId</ID>
      <zIndex>$zIndex</zIndex>
      <IsGroup>false</IsGroup>
      <IsEnabled>true</IsEnabled>
      <Description></Description>
      <IsPSVerified>true</IsPSVerified>
      <ParentID>00000000-0000-0000-0000-000000000000</ParentID>
      <StorageSelectors></StorageSelectors>
      <Content>$fullAbortTemplate</Content>
    </DesignerItem>
"@
        $zIndex++

        $endTop = if ($steps.Count -gt 0) { $steps[-1].Top + 200 } else { 1020 }

        # Connections — main column: Start -> Try/Catch -> Steps -> Конец.
        $connections += New-Conn $startId $tryCatchId 'Next' 'Input' $connZIndex; $connZIndex++
        if ($steps.Count -gt 0) {
            $connections += New-Conn $tryCatchId $steps[0].ID 'Next' 'Input' $connZIndex; $connZIndex++
            for ($i = 0; $i -lt $steps.Count - 1; $i++) {
                $connections += New-Conn $steps[$i].ID $steps[$i+1].ID 'Next' 'Input' $connZIndex; $connZIndex++
            }
            $connections += New-Conn $steps[-1].ID $endId 'Next' 'Input' $connZIndex; $connZIndex++
        } else {
            $connections += New-Conn $tryCatchId $endId 'Next' 'Input' $connZIndex; $connZIndex++
        }
        # Error branch: Try/Catch -> HandleError -> Прервать.
        $connections += New-Conn $tryCatchId $handleErrorId 'Error' 'Input' $connZIndex; $connZIndex++
        $connections += New-Conn $handleErrorId $abortId 'Next' 'Input' $connZIndex; $connZIndex++
    } else {
        # --- MT diagram: Start -> Prepare* -> ReceiveRobotTask -> Switch/Case -> Save* -> End ---
        $mtCount = $manualTasks.Count
        $prepareSteps = @()
        $top = 900
        foreach ($mt in $manualTasks) {
            $prepareSteps += @{ ID = [guid]::NewGuid().ToString(); Name = "Prepare$($mt.stepSuffix)Step"; Top = $top }
            $top += 200
        }
        $receiveId  = [guid]::NewGuid().ToString()
        $receiveTop = 900 + 200 * $mtCount
        $switchId   = [guid]::NewGuid().ToString()
        $switchTop  = $receiveTop + 200
        $saveSteps = @()
        $top = $switchTop + 400
        foreach ($mt in $manualTasks) {
            $saveSteps += @{ ID = [guid]::NewGuid().ToString(); Name = "Save$($mt.stepSuffix)Step"; Top = $top }
            $top += 200
        }
        $endTop = if ($saveSteps.Count -gt 0) { $saveSteps[-1].Top + 200 } else { $switchTop + 200 }

        # Prepare + Save step blocks (reuse the step template; SaveTransaction=True
        # only on the first Prepare, flipped to False on every later block).
        $stepIndex = 0
        foreach ($step in (@($prepareSteps) + @($saveSteps))) {
            $content = $stepTemplate
            $content = $content -replace 'DisplayName="initOrder"', "DisplayName=`"$($step.Name)`""
            $content = $content -replace 'Value="&amp;quot;initOrder&amp;quot;"', "Value=`"&amp;quot;$($step.Name)&amp;quot;`""
            $content = $content -replace 'Value="&amp;quot;demo_init_params&amp;quot;"', "Value=`"&amp;quot;$InitParamsAsset&amp;quot;`""
            $content = $content -replace 'Value="&amp;quot;demo_email_templates&amp;quot;"', "Value=`"&amp;quot;$EmailTemplatesAsset&amp;quot;`""
            $content = $content -replace 'Value="&amp;quot;ТЕСТ&amp;quot;"', "Value=`"&amp;quot;$StepArgs&amp;quot;`""
            if ($stepIndex -gt 0) {
                $content = $content -replace '(&lt;Property Name="SaveTransaction"[^/]*?Value=")True"', '$1False"'
                $content = $content -replace '(&lt;Property Name="SaveTransaction"[^/]*?DefaultValue=")True"', '$1False"'
            }
            $stepBlocks += @"
    <DesignerItem>
      <Left>705</Left>
      <Top>$($step.Top)</Top>
      <Width>200</Width>
      <Height>75</Height>
      <ID>$($step.ID)</ID>
      <zIndex>$zIndex</zIndex>
      <IsGroup>false</IsGroup>
      <IsEnabled>true</IsEnabled>
      <Description></Description>
      <IsPSVerified>true</IsPSVerified>
      <ParentID>00000000-0000-0000-0000-000000000000</ParentID>
      <StorageSelectors></StorageSelectors>
      <Content>$content</Content>
    </DesignerItem>
"@
            $zIndex++
            $stepIndex++
        }

        # ReceiveRobotTask block — substitute the shared queue name; the Sherpa
        # runtime {{{QueueGuid}}} token inside the Code attribute stays intact.
        $receiveContent = $receiveTemplate -replace '\{\{\{MT_QUEUE_NAME\}\}\}', $mtQueueName
        $stepBlocks += @"
    <DesignerItem>
      <Left>715</Left>
      <Top>$receiveTop</Top>
      <Width>200</Width>
      <Height>75</Height>
      <ID>$receiveId</ID>
      <zIndex>$zIndex</zIndex>
      <IsGroup>false</IsGroup>
      <IsEnabled>true</IsEnabled>
      <Description></Description>
      <IsPSVerified>true</IsPSVerified>
      <ParentID>00000000-0000-0000-0000-000000000000</ParentID>
      <StorageSelectors></StorageSelectors>
      <Content>$receiveContent</Content>
    </DesignerItem>
"@
        $zIndex++

        # Switch/Case block — verbatim template; Condition2/3/4 hardcoded 2/3/4
        # (≤3 MTs supported; >3 needs a manual Condition5 + Yes5 connector wiring).
        $switchContent = $switchTemplate
        $stepBlocks += @"
    <DesignerItem>
      <Left>765</Left>
      <Top>$switchTop</Top>
      <Width>100</Width>
      <Height>200</Height>
      <ID>$switchId</ID>
      <zIndex>$zIndex</zIndex>
      <IsGroup>false</IsGroup>
      <IsEnabled>true</IsEnabled>
      <Description></Description>
      <IsPSVerified>true</IsPSVerified>
      <ParentID>00000000-0000-0000-0000-000000000000</ParentID>
      <StorageSelectors></StorageSelectors>
      <Content>$switchContent</Content>
    </DesignerItem>
"@
        $zIndex++

        # Connections — sender chain, then Switch/Case routing, then Save* -> End.
        if ($prepareSteps.Count -gt 0) {
            $connections += New-Conn $startId $prepareSteps[0].ID 'Next' 'Input' $connZIndex; $connZIndex++
            for ($i = 0; $i -lt $prepareSteps.Count - 1; $i++) {
                $connections += New-Conn $prepareSteps[$i].ID $prepareSteps[$i+1].ID 'Next' 'Input' $connZIndex; $connZIndex++
            }
            $connections += New-Conn $prepareSteps[-1].ID $receiveId 'Next' 'Input' $connZIndex; $connZIndex++
        }
        $connections += New-Conn $receiveId $switchId 'Next' 'Input' $connZIndex; $connZIndex++
        # Switch/Case routes by $Parameters.processStage: Yes{stage} -> Save[i]
        # (stage = i+2). Default -> Save[0] InputLeft (primary run; reroute in Designer).
        for ($i = 0; $i -lt $saveSteps.Count; $i++) {
            $stage = $i + 2
            $connections += New-Conn $switchId $saveSteps[$i].ID "Yes$stage" 'Input' $connZIndex; $connZIndex++
        }
        if ($saveSteps.Count -gt 0) {
            $connections += New-Conn $switchId $saveSteps[0].ID 'Default' 'InputLeft' $connZIndex; $connZIndex++
        }
        # Each Save is a parallel branch -> End (only the matched stage runs per run).
        foreach ($s in $saveSteps) {
            $connections += New-Conn $s.ID $endId 'Next' 'Input' $connZIndex; $connZIndex++
        }
    }

    # Build End block (shared — Top/zIndex set by the branch above).
    $endBlock = @"
    <DesignerItem>
      <Left>700</Left>
      <Top>$endTop</Top>
      <Width>70</Width>
      <Height>70</Height>
      <ID>$endId</ID>
      <zIndex>$zIndex</zIndex>
      <IsGroup>false</IsGroup>
      <IsEnabled>true</IsEnabled>
      <Description></Description>
      <IsPSVerified>true</IsPSVerified>
      <ParentID>00000000-0000-0000-0000-000000000000</ParentID>
      <StorageSelectors></StorageSelectors>
      <Content>$endTemplate</Content>
    </DesignerItem>
"@

    # Assemble XML
    $output = @"
<?xml version="1.0" encoding="utf-8"?>
<Root>
  <DesignerItems>
$startBlock
$($stepBlocks -join "`n")
$endBlock
  </DesignerItems>
  <Connections>
$($connections -join "`n")
  </Connections>
  <Properties />
  <PSCache></PSCache>
  <Description></Description>
  <InputArguments></InputArguments>
  <OutputArguments></OutputArguments>
</Root>
"@

    $output | Out-File $Path -Encoding UTF8
}

# === 1. VALIDATE PATH ===
Write-ReportHeader "Workfusion to Sherpa Migration Assistant"
Write-ReportItem "WF Process Path" $WfProcessPath
$displayProjectName = if ($SherpaProjectName) { $SherpaProjectName } else { "[auto-detect]" }
Write-ReportItem "Sherpa Project" $displayProjectName
$displayGenerateCode = if ($GenerateCode) { "YES" } else { "NO" }
Write-ReportItem "Generate Code" $displayGenerateCode "Yellow"

if (-not (Test-Path $WfProcessPath)) {
    Write-Error "Path not found: $WfProcessPath"
    exit 1
}

# Find BCB module
$bcbDirs = Get-ChildItem -Path $WfProcessPath -Directory -Filter "*-bcb" -ErrorAction SilentlyContinue
if (-not $bcbDirs) {
    $report.warnings += "No *-bcb module found. Using root directory."
    $bcbDir = $WfProcessPath
} else {
    $bcbDir = $bcbDirs[0].FullName
    Write-ReportItem "BCB Module" $bcbDirs[0].Name "Green"
}

# Auto-detect project name from directory
if (-not $SherpaProjectName) {
    $dirName = (Get-Item $WfProcessPath).Name
    $SherpaProjectName = $dirName.ToLower() -replace '_', '-'
    $report.projectName = $SherpaProjectName
    Write-ReportItem "Auto-detected Name" $SherpaProjectName "Yellow"
}

# Determine package name
if (-not $PackageName) {
    $pkgSuffix = $SherpaProjectName -replace '-', '_'
    $PackageName = "by.a1.$pkgSuffix"
    Write-ReportItem "Auto-detected Package" $PackageName "Yellow"
}

# Determine output path
if (-not $OutputPath -and $GenerateCode) {
    # Default: create alongside the WF process, in a sibling directory
    $parent = (Get-Item $WfProcessPath).Parent.FullName
    $OutputPath = Join-Path $parent "sherpa-generated\$SherpaProjectName"
    Write-ReportItem "Auto-detected Output" $OutputPath "Yellow"
}

# === 2. SCAN XML CONFIGS ===
Write-ReportHeader "Step Analysis"

$configDir = Join-Path $bcbDir "src\main\resources\configs\main"
if (Test-Path $configDir) {
    $xmlFiles = Get-ChildItem -Path $configDir -Filter "*.xml" | Sort-Object Name
    Write-ReportItem "XML Configs Found" $xmlFiles.Count "Green"

    foreach ($xmlFile in $xmlFiles) {
        try {
            [xml]$xmlContent = Get-Content $xmlFile.FullName -Encoding UTF8 -Raw
            $stepType = "server-side"
            $hasRoboticsFlow = $false
            $hasPool = $false
            $processorName = $null
            $fleet = $null

            $roboticsFlow = $xmlContent.SelectNodes("//*[local-name()='robotics-flow']")
            if ($roboticsFlow.Count -gt 0) {
                $hasRoboticsFlow = $true
                $stepType = "desktop"
                if ($roboticsFlow[0].HasAttribute("fleet")) {
                    $fleet = $roboticsFlow[0].GetAttribute("fleet")
                    if ($fleet -eq "SAP") { $stepType = "sap" }
                }
                $robot = $xmlContent.SelectNodes("//*[local-name()='robot']")
                if ($robot.Count -gt 0 -and $robot[0].HasAttribute("driver")) {
                    $driver = $robot[0].GetAttribute("driver")
                    if ($driver -eq "desktop") {
                        $stepType = if ($fleet -eq "SAP") { "sap" } else { "desktop" }
                    }
                }
            }

            $pool = $xmlContent.SelectNodes("//*[local-name()='pool']")
            if ($pool.Count -gt 0) {
                $hasPool = $true
                if ($stepType -eq "server-side") { $stepType = "parallel" }
            }

            $scriptContent = ""
            $scriptNodes = $xmlContent.SelectNodes("//*[local-name()='script']")
            foreach ($node in $scriptNodes) { $scriptContent += $node.InnerText }

            $processorMatches = [regex]::Matches($scriptContent, 'import\s+([\w.]+)\.processor\.(\w+)')
            foreach ($match in $processorMatches) {
                $processorName = $match.Groups[2].Value -replace 'Processor$', ''
                if ($processorName) { break }
            }
            if (-not $processorName) {
                $txMatches = [regex]::Matches($scriptContent, 'processTransaction\(\s*(\w+)\.class')
                foreach ($match in $txMatches) {
                    $processorName = $match.Groups[1].Value -replace 'Processor$', ''
                    if ($processorName) { break }
                }
            }

            $report.steps += @{
                file = $xmlFile.Name
                type = $stepType
                processor = $processorName
                hasPool = $hasPool
                fleet = $fleet
            }

            $typeColor = switch ($stepType) {
                "sap" { "Magenta" }
                "desktop" { "Blue" }
                "parallel" { "Cyan" }
                "server-side" { "Green" }
                default { "White" }
            }
            Write-Host "  [$($xmlFile.Name)] " -NoNewline -ForegroundColor Gray
            Write-Host "$stepType" -NoNewline -ForegroundColor $typeColor
            if ($processorName) {
                Write-Host " → $processorName" -NoNewline -ForegroundColor Yellow
            }
            if ($hasPool) { Write-Host " [POOL]" -NoNewline -ForegroundColor Cyan }
            Write-Host ""
        } catch {
            $report.errors += "Failed to parse $($xmlFile.Name): $($_.Exception.Message)"
            Write-ReportItem "ERROR" $xmlFile.Name "Red"
        }
    }
} else {
    $report.warnings += "No configs/main directory found"
    Write-ReportItem "XML Configs" "Not found" "Red"
}

# === 3. SCAN RESOURCES ===
Write-ReportHeader "Resource Analysis"
$resourcesDir = Join-Path $bcbDir "src\main\resources"
if (Test-Path $resourcesDir) {
    $psScripts = Get-ChildItem -Path $resourcesDir -Filter "*.ps1" -Recurse -ErrorAction SilentlyContinue
    if ($psScripts) {
        $report.powerShellScripts = $psScripts | ForEach-Object { $_.Name }
        Write-ReportItem "PowerShell Scripts" $psScripts.Count "Green"
        foreach ($s in $psScripts) { Write-Host "    - $($s.Name)" -ForegroundColor Gray }
    } else {
        Write-ReportItem "PowerShell Scripts" "None" "Gray"
    }

    $mtDir = Join-Path $resourcesDir "mt"
    if (Test-Path $mtDir) {
        # Backward-compat: flat file list (all files under mt/, recursive)
        $allMtFiles = Get-ChildItem -Path $mtDir -File -Recurse -ErrorAction SilentlyContinue
        if ($allMtFiles) { $report.manualTaskFiles = $allMtFiles | ForEach-Object { $_.Name } }

        # Per-subfolder MT detection: each mt_XX subfolder = one micro-transaction (MT).
        $mtSubdirs = Get-ChildItem -Path $mtDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name
        if ($mtSubdirs) {
            Write-ReportItem "Manual Tasks (MT)" $mtSubdirs.Count "Magenta"
            $mtIndex = 0
            foreach ($sub in $mtSubdirs) {
                $mtIndex++
                $mtNumber = '{0:D2}' -f $mtIndex
                $htmlFiles = @(Get-ChildItem -Path $sub.FullName -Filter "*.html" -ErrorAction SilentlyContinue)
                $jsFiles   = @(Get-ChildItem -Path $sub.FullName -Filter "*.js"   -ErrorAction SilentlyContinue)
                $mtName = if ($htmlFiles) { $htmlFiles[0].BaseName } else { $sub.Name }
                $hasFreemarker = $false
                foreach ($h in $htmlFiles) {
                    $c = Get-Content $h.FullName -Raw -ErrorAction SilentlyContinue
                    if ($c -match '<@(hit|answers|editable|continue|component|inputText)') { $hasFreemarker = $true }
                }
                if ($hasFreemarker) {
                    $msg = "MT $mtNumber ($mtName): FreeMarker detected — convert to ShadowCore (actions/$mtName.js), do NOT copy mt.html verbatim"
                    $report.warnings += $msg
                    Write-Host "    WARNING $msg" -ForegroundColor Yellow
                }
                $report.manualTasks += @{
                    name=$mtName; folder=$sub.Name; mtNumber=$mtNumber
                    pascalName=(ConvertTo-PascalCase $mtName)
                    camelName=(ConvertTo-CamelCase $mtName)
                    # Step class suffix strips the conventional "process_" prefix so the
                    # MT pair matches the WF processor name (process_new -> New ->
                    # PrepareNewStep / SaveNewStep, the canonical MT pair naming).
                    stepSuffix=(ConvertTo-PascalCase ($mtName -replace '^process_',''))
                    constName=(ConvertTo-ConstantCase $mtName)
                    htmlFiles=@($htmlFiles | ForEach-Object { $_.Name })
                    jsFiles=@($jsFiles | ForEach-Object { $_.Name })
                    hasFreemarker=$hasFreemarker
                }
                Write-Host "    - MT $mtNumber : $mtName ($($htmlFiles.Count) html, $($jsFiles.Count) js)" -ForegroundColor Gray
            }
        } else {
            $mtFiles = Get-ChildItem -Path $mtDir -File -ErrorAction SilentlyContinue
            if ($mtFiles) {
                $report.manualTaskFiles = $mtFiles | ForEach-Object { $_.Name }
                Write-ReportItem "Manual Task Files (flat)" $mtFiles.Count "Magenta"
                foreach ($f in $mtFiles) { Write-Host "    - $($f.Name)" -ForegroundColor Gray }
            }
        }
    } else {
        Write-ReportItem "Manual Task" "Not found" "Gray"
    }

    # Central MT flag + shared queue name (Sherpa process / Designer name).
    # Threaded through every MT generator section; non-MT output is byte-identical to today.
    $hasMt = $report.manualTasks.Count -gt 0
    $mtQueueName = if ($DesignerProjectName) { $DesignerProjectName } else { $SherpaProjectName }
} else {
    Write-ReportItem "Resources" "Not found" "Red"
}

# === 4. SCAN JAVA CLASSES ===
Write-ReportHeader "Java Class Analysis"
$javaDir = Join-Path $bcbDir "src\main\java"
if (Test-Path $javaDir) {
    $initParamsFiles = Get-ChildItem -Path $javaDir -Filter "AppInitParams.java" -Recurse -ErrorAction SilentlyContinue
    if ($initParamsFiles) {
        $content = Get-Content $initParamsFiles[0].FullName -Raw
        $fieldMatches = [regex]::Matches($content, 'private\s+(?:final\s+)?(\w+(?:<[^>]+>)?)\s+(\w+)\s*;')
        foreach ($match in $fieldMatches) {
            $report.initParams += @{ type = $match.Groups[1].Value; name = $match.Groups[2].Value }
        }
        Write-ReportItem "AppInitParams Fields" $fieldMatches.Count "Green"
    } else {
        $report.warnings += "AppInitParams.java not found"
        Write-ReportItem "AppInitParams" "Not found" "Yellow"
    }

    $docFiles = @("AppDoc.java", "AppTransaction.java")
    foreach ($docFile in $docFiles) {
        $found = Get-ChildItem -Path $javaDir -Filter $docFile -Recurse -ErrorAction SilentlyContinue
        if ($found) {
            $content = Get-Content $found[0].FullName -Raw
            $constMatches = [regex]::Matches($content, 'public\s+static\s+final\s+String\s+(\w+)\s*=')
            foreach ($match in $constMatches) {
                $report.dataKeys += $match.Groups[1].Value
            }
            Write-ReportItem "$docFile Constants" $constMatches.Count "Green"
        }
    }

    $processorDir = Get-ChildItem -Path $javaDir -Directory -Recurse -Filter "processor" -ErrorAction SilentlyContinue
    if ($processorDir) {
        $processors = Get-ChildItem -Path $processorDir[0].FullName -Filter "*.java"
        Write-ReportItem "Processor Classes" $processors.Count "Green"
        foreach ($proc in $processors) {
            $procName = $proc.BaseName -replace 'Processor$', ''
            $report.processors += $procName
            Write-Host "    - $($proc.Name) → ${procName}Step" -ForegroundColor Gray

            $procContent = Get-Content $proc.FullName -Raw
            if ($procContent -match 'email|mail|smtp|imap') { if ($report.services -notcontains "email") { $report.services += "email" } }
            if ($procContent -match 'ad|ldap|active.?directory|ADService') { if ($report.services -notcontains "active-directory") { $report.services += "active-directory" } }
            if ($procContent -match 'sap|SAP|SapGui|RobotDriver') { if ($report.services -notcontains "sap") { $report.services += "sap" } }
            if ($procContent -match 'jira|JIRA|Jsd|JSD') { if ($report.services -notcontains "jira") { $report.services += "jira" } }
            if ($procContent -match 'sharepoint|SharePoint') { if ($report.services -notcontains "sharepoint") { $report.services += "sharepoint" } }
            if ($procContent -match 'sql|jdbc|database|mssql|sqlserver') { if ($report.services -notcontains "mssql") { $report.services += "mssql" } }
            if ($procContent -match 'oracle|ojdbc|Oracle') { if ($report.services -notcontains "oracle") { $report.services += "oracle" } }
            if ($procContent -match 'powershell|PowerShell|jPowerShell') { if ($report.services -notcontains "powershell") { $report.services += "powershell" } }
            if ($procContent -match 'excel|poi|poiji|xlsx|xls') { if ($report.services -notcontains "excel") { $report.services += "excel" } }
            if ($procContent -match 'okhttp|httpclient|rest|http') { if ($report.services -notcontains "http") { $report.services += "http" } }
            if ($procContent -match 'jsoup|html|htmlparser') { if ($report.services -notcontains "html") { $report.services += "html" } }
        }
    } else {
        $report.warnings += "No processor directory found"
        Write-ReportItem "Processors" "Not found" "Yellow"
    }
} else {
    $report.warnings += "No Java source directory found"
    Write-ReportItem "Java Sources" "Not found" "Red"
}

# === 5. DEPENDENCY MAPPING ===
Write-ReportHeader "Sherpa Dependencies"

$depMap = @{
    "email" = @("rpa-core (already included)")
    "active-directory" = @("rpa-ad")
    "sap" = @("rpa-sapgui", "libs/jacob.jar")
    "jira" = @("rpa-jira")
    "sharepoint" = @("rpa-sharepoint")
    "mssql" = @("com.microsoft.sqlserver:mssql-jdbc:12.6.1.jre11")
    "oracle" = @("com.oracle.database.jdbc:ojdbc11:21.9.0.0", "com.oracle.database.nls:orai18n:21.9.0.0")
    "powershell" = @("com.profesorfalken:jPowerShell:3.1.1")
    "excel" = @("com.github.ozlerhakan:poiji:5.2.0")
    "http" = @("com.squareup.okhttp3:okhttp", "com.squareup.okhttp3:logging-interceptor")
    "html" = @("org.jsoup:jsoup:1.21.2")
}

$allDeps = @("rpa-core", "lombok")
foreach ($svc in $report.services) {
    if ($depMap.ContainsKey($svc)) {
        foreach ($dep in $depMap[$svc]) {
            if ($allDeps -notcontains $dep) {
                $allDeps += $dep
                $report.dependencies += $dep
            }
        }
    }
}

Write-ReportItem "Detected Services" ($report.services -join ", ") "Green"
Write-ReportItem "Required Dependencies" ($report.dependencies.Count) "Green"
foreach ($dep in $report.dependencies) {
    Write-Host "    - $dep" -ForegroundColor Gray
}

# === 6. GENERATE JAVA FILES (if requested) ===
if ($GenerateCode) {
    Write-ReportHeader "Generating Java Files"

    # Create directories
    $javaBase = Join-Path $OutputPath "src\main\java\$($PackageName -replace '\.', '\')"
    $modelDir = Join-Path $javaBase "model"
    $transactionDir = Join-Path $javaBase "transaction"
    $stepsDir = Join-Path $javaBase "steps"
    $resourcesDir = Join-Path $OutputPath "src\main\resources"

    New-Item -ItemType Directory -Force -Path $modelDir | Out-Null
    New-Item -ItemType Directory -Force -Path $transactionDir | Out-Null
    New-Item -ItemType Directory -Force -Path $stepsDir | Out-Null
    New-Item -ItemType Directory -Force -Path $resourcesDir | Out-Null

    # --- Generate InitParameters.java ---
    $initFields = @()
    foreach ($field in $report.initParams) {
        $javaType = switch -Regex ($field.type) {
            "boolean" { "boolean" }
            "int" { "Integer" }
            "double" { "Double" }
            default { "String" }
        }
        $fieldName = $field.name
        $initFields += "  private final $javaType $fieldName;"
    }
    # MT Action links — appended AFTER business fields. @AllArgsConstructor order:
    # EmailRecipients → controllerEmail → WF business fields → MT ActionLinks (the
    # canonical 13-arg order). Sender step uses the matching get{MtPascal}ActionLink().
    if ($hasMt) {
        $initFields += ""
        $initFields += "  // MT Action links (UUID references to Sherpa Designer Actions)"
        foreach ($mt in $report.manualTasks) {
            # camelCase canonical (processNewActionLink); Lombok @Getter
            # derives get{PascalName}ActionLink(), which the sender step calls.
            $actionField = $mt.camelName + "ActionLink"
            $initFields += "  private final String $actionField;"
        }
    }
    $initFieldsStr = $initFields -join "`n"

    $initJava = @"
package $PackageName.model;

import by.a1.rpa.email.model.EmailRecipients;
import lombok.AllArgsConstructor;
import lombok.Getter;
import lombok.ToString;

@AllArgsConstructor
@Getter
@ToString
public class InitParameters {

  private final EmailRecipients emailRecipients;  // MANDATORY — never remove!
  private final String controllerEmail;

  // Fields from WF AppInitParams
$initFieldsStr
}
"@
    $initPath = Join-Path $modelDir "InitParameters.java"
    $initJava | Out-File -FilePath $initPath -Encoding UTF8
    Write-ReportItem "Generated" "InitParameters.java ($($report.initParams.Count) fields)" "Green"

    # --- Generate ProcessDataKeys.java ---
    $keyConstants = @()
    foreach ($key in $report.dataKeys) {
        $constName = ConvertTo-ConstantCase $key
        $keyConstants += "  public static final String $constName = `"$key`";"
    }
    $keyConstantsStr = $keyConstants -join "`n"

    # MT constants (only when MT detected): one shared queue (MT_01 value, aliased by
    # MT_02+), per-MT name/taskName/tag triple, SHERPA_API_CREDENTIALS_ASSET, and
    # STATUS_*_EXIST / STATUS_NO_* workflow-status literals per MT.
    $mtConstants = @()
    if ($hasMt) {
        $firstMtNumber = $report.manualTasks[0].mtNumber
        $mtConstants += "  public static final String MT_${firstMtNumber}_QUEUE_NAME = `"$mtQueueName`";"
        foreach ($mt in $report.manualTasks) {
            $nn = $mt.mtNumber
            $taskName = $mt.camelName   # e.g. processNew / processChanged / processAll
            $mtConstants += ""
            $mtConstants += "  public static final String MT_${nn}_NAME = `"$($mt.name)`"; // TODO: human-readable MT name (used in emails)"
            if ($nn -ne $firstMtNumber) {
                $mtConstants += "  public static final String MT_${nn}_QUEUE_NAME = MT_${firstMtNumber}_QUEUE_NAME;"
            }
            $mtConstants += "  public static final String MT_${nn}_TASK_NAME = `"$taskName`";"
            $mtConstants += "  public static final String MT_${nn}_PENDING_TAG = `"pending`";   // TODO: refine per MT (pendingChanged/pendingAll for MT_02+) — keep in sync with actions/$($mt.name).js"
            $mtConstants += "  public static final String MT_${nn}_FINAL_TAG = `"reviewed`";     // TODO: refine per MT — keep in sync with actions/$($mt.name).js"
            $mtConstants += "  public static final String MT_${nn}_PROCESSED_TAG = `"processed`"; // TODO: refine per MT"
        }
        $mtConstants += ""
        $mtConstants += "  public static final String SHERPA_API_CREDENTIALS_ASSET = `"sherpa_api_credentials`";"
        foreach ($mt in $report.manualTasks) {
            $const = $mt.constName
            $statusLiteral = ($mt.name -replace '\s+','_')
            $mtConstants += "  public static final String STATUS_${const}_EXIST = `"$statusLiteral`";"
            $mtConstants += "  public static final String STATUS_NO_${const} = `"no_$statusLiteral`";"
        }
    }
    $mtConstantsStr = $mtConstants -join "`n"

    $mtConstantsBlock = if ($hasMt) {
        @"

  // === Manual Task (MT) constants — canonical ===
$mtConstantsStr
"@
    } else { "" }

    $keysJava = @"
package $PackageName.transaction;

import lombok.AccessLevel;
import lombok.NoArgsConstructor;

@NoArgsConstructor(access = AccessLevel.PRIVATE)
public final class ProcessDataKeys {

  // Email recipients
  public static final String EMAIL_RECIPIENTS = "email_recipients";

  // Workflow status
  public static final String WORKFLOW_STATUS = "workflow_status";
  public static final String STATUS_NEXT = "status_next";
  public static final String STATUS_EXIT = "status_exit";

  // Fields from WF AppDoc / AppTransaction
$keyConstantsStr$mtConstantsBlock
}
"@
    $keysPath = Join-Path $transactionDir "ProcessDataKeys.java"
    $keysJava | Out-File -FilePath $keysPath -Encoding UTF8
    Write-ReportItem "Generated" "ProcessDataKeys.java ($($report.dataKeys.Count) constants)" "Green"

    # --- Generate ProcessTransaction.java ---
    $getSetMethods = @()
    foreach ($key in $report.dataKeys) {
        $pascalKey = ConvertTo-PascalCase $key
        $constName = ConvertTo-ConstantCase $key
        $getSetMethods += @"

  public void set$pascalKey(String value) {
    transaction.setStepData(ProcessDataKeys.$constName, value);
  }

  public Optional<String> get$pascalKey() {
    return transaction.getStepData(ProcessDataKeys.$constName, String.class);
  }
"@
    }
    $getSetMethodsStr = $getSetMethods -join ""

    # MT workflow-status helpers — the Prepare/Save step templates call
    # getWorkflowStatus()/setWorkflowStatus(); add them only when MT detected.
    $mtTxMethods = ""
    if ($hasMt) {
        $mtTxMethods = @"

  // MT workflow status — read/written by Prepare*/Save* step pairs.
  public Optional<String> getWorkflowStatus() {
    return transaction.getStepData(ProcessDataKeys.WORKFLOW_STATUS, String.class);
  }

  public void setWorkflowStatus(String status) {
    transaction.setStepData(ProcessDataKeys.WORKFLOW_STATUS, status);
  }
"@
    }

    $txJava = @"
package $PackageName.transaction;

import $PackageName.model.InitParameters;
import by.a1.rpa.core.transaction.Transaction;
import com.google.gson.Gson;
import com.google.gson.reflect.TypeToken;
import java.util.List;
import java.util.Optional;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@RequiredArgsConstructor
public class ProcessTransaction {

  public static final Gson GSON = new Gson();
  private final Transaction transaction;

  // Generic setter for any DTO list
  public <T> void setData(String key, List<T> data) {
    transaction.setStepData(key, GSON.toJson(data));
  }

  // Generic getter for any DTO list
  public <T> Optional<List<T>> getData(String key, Class<T> clazz) {
    return transaction.getStepData(key, new TypeToken<List<T>>() {}.getType());
  }

  // String status helpers
  public void setStatus(String status) {
    transaction.setStepData(ProcessDataKeys.WORKFLOW_STATUS, status);
  }

  public Optional<String> getStatus() {
    return transaction.getStepData(ProcessDataKeys.WORKFLOW_STATUS, String.class);
  }

  // Get/set for each data key from WF
$getSetMethodsStr$mtTxMethods
}
"@
    $txPath = Join-Path $transactionDir "ProcessTransaction.java"
    $txJava | Out-File -FilePath $txPath -Encoding UTF8
    Write-ReportItem "Generated" "ProcessTransaction.java ($($report.dataKeys.Count) get/set methods)" "Green"

    # --- Generate MtResult DTOs (MT detected) ---
    if ($hasMt) {
        foreach ($mt in $report.manualTasks) {
            $resultJava = @"
package $PackageName.model;

import com.google.gson.annotations.SerializedName;
import java.util.List;
import java.util.Map;
import lombok.Data;

@Data
public class $($mt.pascalName)Result {

  private UserInput userInput;

  @Data
  public static class UserInput {
    // TODO: replace Map<String,Object> with the concrete entity DTO once the form
    // payload shape is known (must match actions/$($mt.name).js onReady + submit).
    @SerializedName("processedAccounts")
    private List<Map<String, Object>> processedAccounts;
  }
}
"@
            $resultPath = Join-Path $modelDir "$($mt.pascalName)Result.java"
            $resultJava | Out-File -FilePath $resultPath -Encoding UTF8
        }
        Write-ReportItem "Generated" "$($report.manualTasks.Count) MT Result DTOs" "Green"
    }

    # --- Generate Step classes ---
    # MT-list-driven: when MT detected, emit a Prepare{Mt}Step/Save{Mt}Step pair per
    # MT (sender + receiver), then a generic step for any non-MT processor not
    # already consumed. Without MT, emit one generic {Processor}Step per processor
    # (byte-identical to the original generator).
    $stepCount = 0
    if (-not $hasMt) {
        foreach ($proc in $report.processors) {
            $stepName = "${proc}Step"
            $stepJava = New-GenericStepJava -Proc $proc -Pkg $PackageName
            $stepPath = Join-Path $stepsDir "$stepName.java"
            $stepJava | Out-File -FilePath $stepPath -Encoding UTF8
            $stepCount++
        }
    } else {
        $emittedStepNames = @{}
        foreach ($mt in $report.manualTasks) {
            # processStage: MT index 1-based -> stage = index + 1 (MT_01->2, MT_02->3, MT_03->4).
            # Stage 1 = initial run (no task); Switch/Case routes receivers by this value.
            $stage = [int]$mt.mtNumber + 1
            $mtPascal = $mt.pascalName      # ProcessNew — getter get{mtPascal}ActionLink, DTO {mtPascal}Result
            $mtStep = $mt.stepSuffix         # New — Prepare/Save class suffix (matches WF processor name)
            $mtConst = $mt.constName
            $mtNum = $mt.mtNumber

            # --- Prepare{Mt}Step.java (sender) ---
            $prepareJava = @"
package $PackageName.steps;

import $PackageName.model.InitParameters;
import $PackageName.transaction.ProcessDataKeys;
import $PackageName.transaction.ProcessTransaction;
import by.a1.rpa.core.Step;
import by.a1.rpa.core.StepName;
import by.a1.rpa.core.transaction.Transaction;
import by.a1.rpa.email.EmailService;
import by.a1.rpa.email.model.EmailRecipients;
import by.a1.rpa.orchestrator.OrchestratorService;
import by.a1.rpa.orchestrator.model.Asset;
import com.google.inject.Inject;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@StepName("Prepare${mtStep}Step")
public class Prepare${mtStep}Step implements Step {

  private final EmailService emailService;
  private final OrchestratorService orchestratorService;

  @Inject
  public Prepare${mtStep}Step(EmailService emailService, OrchestratorService orchestratorService) {
    this.emailService = emailService;
    this.orchestratorService = orchestratorService;
  }

  @Override
  public void execute(Transaction transaction, List<String> args) {
    String className = this.getClass().getSimpleName();
    log.info("Start {}", className);

    ProcessTransaction processTransaction = new ProcessTransaction(transaction);
    InitParameters initParams = getInitParameters(transaction);
    EmailRecipients emailRecipients = initParams.getEmailRecipients();

    // TODO: compute the data set for MT $mtNum (adapt from the WF Prepare processor).
    boolean hasData = true; // TODO: replace with the real check

    if (!hasData) {
      sendMailNoNewTask(emailRecipients);
      processTransaction.setWorkflowStatus(ProcessDataKeys.STATUS_NO_${mtConst});
      createAutoTriggerTask();
    } else {
      processTransaction.setWorkflowStatus(ProcessDataKeys.STATUS_${mtConst}_EXIST);
      createManualTask();
      sendMailNewTask(emailRecipients, initParams.get${mtPascal}ActionLink());
    }
    log.info("Finish {}", className);
  }

  // Manual path: full payload + bearerToken, task created with PENDING_TAG (stays NEW).
  private void createManualTask() {
    Asset.Credentials sherpaApiCredentials = orchestratorService
        .assets().getCredentials(ProcessDataKeys.SHERPA_API_CREDENTIALS_ASSET).execute();
    Map<String, Object> payload = new LinkedHashMap<>();
    // TODO: put form-data keys (must match actions/$($mt.name).js onReady + ${mtPascal}Result.UserInput).
    payload.put("bearerToken", sherpaApiCredentials.password());
    orchestratorService.tasks().create()
        .queue(ProcessDataKeys.MT_${mtNum}_QUEUE_NAME)
        .name(ProcessDataKeys.MT_${mtNum}_TASK_NAME)
        .tags(ProcessDataKeys.MT_${mtNum}_PENDING_TAG)
        .parameters(Map.of("initialData", payload, "transactionName", resolveTransactionName(),
            "processStage", $stage))
        .execute();
  }

  // Auto-trigger path (skip branch): empty payload, task created directly with
  // FINAL_TAG in NEW so the orchestrator trigger fires the receiver without a human.
  private void createAutoTriggerTask() {
    orchestratorService.tasks().create()
        .queue(ProcessDataKeys.MT_${mtNum}_QUEUE_NAME)
        .name(ProcessDataKeys.MT_${mtNum}_TASK_NAME)
        .tags(ProcessDataKeys.MT_${mtNum}_FINAL_TAG)
        .parameters(Map.of("initialData", Map.of(), "transactionName", resolveTransactionName(),
            "processStage", $stage))
        .execute();
  }

  // transactionName = transaction file name without extension (ReceiveRobotTask
  // downloads the file from Storage by this name).
  private String resolveTransactionName() {
    String txPathProp = System.getProperty("transaction.path");
    if (txPathProp == null || txPathProp.isBlank()) {
      throw new IllegalStateException("Missing system property 'transaction.path'");
    }
    Path transactionPath = Path.of(txPathProp).toAbsolutePath().normalize();
    String filename = transactionPath.getFileName().toString();
    return filename.substring(0, filename.lastIndexOf('.'));
  }

  private void sendMailNewTask(EmailRecipients recipients, String actionUrl) {
    Map<String, Object> values = new HashMap<>();
    values.put("mtName", ProcessDataKeys.MT_${mtNum}_NAME);
    values.put("actionUrl", actionUrl);
    // TODO: emailService.sendByTemplateName("new_tasks", values, recipients);
  }

  private void sendMailNoNewTask(EmailRecipients recipients) {
    Map<String, Object> values = new HashMap<>();
    values.put("mtName", ProcessDataKeys.MT_${mtNum}_NAME);
    // TODO: emailService.sendByTemplateName("no_new_tasks", values, recipients);
  }

  private InitParameters getInitParameters(Transaction transaction) {
    return transaction.getInitParameters(InitParameters.class)
        .orElseThrow(() -> new IllegalStateException("InitParameters not found"));
  }
}
"@
            $preparePath = Join-Path $stepsDir "Prepare${mtStep}Step.java"
            $prepareJava | Out-File -FilePath $preparePath -Encoding UTF8
            $stepCount++
            $emittedStepNames["Prepare${mtStep}Step"] = $true

            # --- Save{Mt}Step.java (receiver) ---
            $saveJava = @"
package $PackageName.steps;

import $PackageName.model.InitParameters;
import $PackageName.model.${mtPascal}Result;
import $PackageName.transaction.ProcessDataKeys;
import $PackageName.transaction.ProcessTransaction;
import by.a1.rpa.core.Step;
import by.a1.rpa.core.StepName;
import by.a1.rpa.core.exception.BusinessException;
import by.a1.rpa.core.transaction.Transaction;
import by.a1.rpa.email.EmailService;
import by.a1.rpa.email.model.EmailRecipients;
import by.a1.rpa.orchestrator.OrchestratorService;
import by.a1.rpa.orchestrator.model.Task;
import by.a1.rpa.orchestrator.model.TaskStatus;
import com.google.gson.Gson;
import com.google.inject.Inject;
import java.util.List;
import java.util.Optional;
import lombok.extern.slf4j.Slf4j;

@Slf4j
@StepName("Save${mtStep}Step")
public class Save${mtStep}Step implements Step {

  private static final Gson GSON = new Gson();
  private final EmailService emailService;
  private final OrchestratorService orchestratorService;

  @Inject
  public Save${mtStep}Step(EmailService emailService, OrchestratorService orchestratorService) {
    this.emailService = emailService;
    this.orchestratorService = orchestratorService;
  }

  @Override
  public void execute(Transaction transaction, List<String> args) {
    String className = this.getClass().getSimpleName();
    log.info("Start {}", className);
    try {
      ProcessTransaction processTransaction = new ProcessTransaction(transaction);
      EmailRecipients recipients = getInitParameters(transaction).getEmailRecipients();
      Task submittedTask = findSubmittedTask();
      String workflowStatus = processTransaction.getWorkflowStatus().orElse(null);

      if (ProcessDataKeys.STATUS_${mtConst}_EXIST.equals(workflowStatus)) {
        processSubmittedAccounts(processTransaction, submittedTask, recipients);
      } else {
        log.info("Skipping MT $mtNum account processing (workflow_status='{}')", workflowStatus);
      }

      // FINALIZE in EVERY branch — SUCCESS + swap tags to PROCESSED prevents re-trigger.
      markTaskSuccess(submittedTask.getGuid());
      markTaskProcessed(submittedTask.getGuid());
      log.info("Finish {}", className);
    } catch (Exception e) {
      log.error("Failed to process MT $mtNum results: {}", e.getMessage(), e);
      throw new BusinessException("Process MT $mtNum results failed", e);
    }
  }

  // Pick the submitted task: name + FINAL_TAG + status NEW (triggers fire on NEW).
  // Decoy tasks with the final tag but a different name or a non-NEW status are dropped.
  private Task findSubmittedTask() {
    List<Task> tasks = orchestratorService.tasks()
        .listFromQueue(ProcessDataKeys.MT_${mtNum}_QUEUE_NAME).execute();
    return tasks.stream()
        .filter(t -> ProcessDataKeys.MT_${mtNum}_TASK_NAME.equals(t.getName()))
        .filter(t -> t.getTagList().contains(ProcessDataKeys.MT_${mtNum}_FINAL_TAG))
        .filter(t -> t.getStatus() == TaskStatus.NEW)
        .findFirst()
        .orElseThrow(() -> new IllegalStateException(
            "No MT $mtNum task with final tag and status NEW in queue"));
  }

  private void processSubmittedAccounts(ProcessTransaction processTransaction, Task task,
      EmailRecipients recipients) {
    // TODO: parse ${mtPascal}Result, merge into transaction, sendMailTaskProcessed.
    ${mtPascal}Result result = parseTaskIntoResult(task);
    log.info("Processed accounts from MT ${mtNum}: {}", result.getUserInput());
  }

  private ${mtPascal}Result parseTaskIntoResult(Task task) {
    try {
      var parameters = task.getParameters();
      if (parameters != null && parameters.getParametersMap() != null) {
        Object initial = parameters.getParametersMap().get("initialData");
        if (initial instanceof Map<?, ?> m) return GSON.fromJson(GSON.toJson(m), ${mtPascal}Result.class);
        if (initial instanceof String s && !s.isBlank() && !"[object Object]".equals(s))
          return GSON.fromJson(s, ${mtPascal}Result.class);
      }
      var root = GSON.fromJson(task.getRawParameters(), com.google.gson.JsonObject.class);
      var text = root.getAsJsonObject("text");
      if (text != null && text.has("initialData") && !text.get("initialData").isJsonNull())
        return GSON.fromJson(text.get("initialData"), ${mtPascal}Result.class);
      throw new IllegalStateException("MT $mtNum task has no initialData");
    } catch (Exception e) {
      throw new BusinessException("Failed to parse MT $mtNum task " + task.getGuid(), e);
    }
  }

  // Two separate update() calls: tags() fully replaces the tag list; the server
  // ignores empty tags, so PROCESSED_TAG is non-empty to clear pending/reviewed.
  private void markTaskSuccess(String taskGuid) {
    orchestratorService.tasks().update(taskGuid).status(TaskStatus.SUCCESS).execute();
  }

  private void markTaskProcessed(String taskGuid) {
    orchestratorService.tasks().update(taskGuid).tags(ProcessDataKeys.MT_${mtNum}_PROCESSED_TAG).execute();
  }

  private InitParameters getInitParameters(Transaction transaction) {
    return transaction.getInitParameters(InitParameters.class)
        .orElseThrow(() -> new IllegalStateException("InitParameters not found"));
  }
}
"@
            $savePath = Join-Path $stepsDir "Save${mtStep}Step.java"
            $saveJava | Out-File -FilePath $savePath -Encoding UTF8
            $stepCount++
            $emittedStepNames["Save${mtStep}Step"] = $true
        }

        # Generic step for any non-MT processor not already consumed by an MT pair.
        foreach ($proc in $report.processors) {
            $stepName = "${proc}Step"
            if (-not $emittedStepNames.ContainsKey($stepName)) {
                $stepJava = New-GenericStepJava -Proc $proc -Pkg $PackageName
                $stepPath = Join-Path $stepsDir "$stepName.java"
                $stepJava | Out-File -FilePath $stepPath -Encoding UTF8
                $stepCount++
            }
        }
    }
    Write-ReportItem "Generated" "$stepCount Step classes" "Green"

    # --- Generate build.gradle ---
    $depLines = @()
    foreach ($dep in $report.dependencies) {
        if ($dep -eq "rpa-core (already included)") { continue }
        if ($dep -eq "rpa-ad" -or $dep -eq "rpa-jira" -or $dep -eq "rpa-sapgui" -or $dep -eq "rpa-sharepoint") {
            $depLines += "    implementation project(':$dep')"
        } elseif ($dep -eq "libs/jacob.jar") {
            $depLines += "    implementation files('$dep')"
        } elseif ($dep -match ':') {
            $depLines += "    implementation '$dep'"
        } else {
            $depLines += "    // $dep"
        }
    }
    $depLinesStr = $depLines -join "`n"

    $shadowName = $SherpaProjectName
    $gradle = @"
plugins {
    id 'application'
    id 'com.github.johnrengelman.shadow' version '8.1.1'
}

group = '$PackageName'
version = '1.0.0'

repositories {
    mavenCentral()
}

dependencies {
    implementation project(':rpa-core')
$depLinesStr

    testImplementation platform('org.junit:junit-bom:5.10.0')
    testImplementation 'org.junit.jupiter:junit-jupiter'
    testImplementation 'org.mockito:mockito-core:5.7.0'

    compileOnly 'org.projectlombok:lombok:1.18.40'
    annotationProcessor 'org.projectlombok:lombok:1.18.40'
    testCompileOnly 'org.projectlombok:lombok:1.18.40'
    testAnnotationProcessor 'org.projectlombok:lombok:1.18.40'
}

application {
    mainClass = 'by.a1.rpa.core.StepRunnerMain'
    applicationDefaultJvmArgs = ['-Xmx512m', '-XX:+UseG1GC']
}

shadowJar {
    archiveBaseName.set('$shadowName')
    archiveClassifier.set('')
    mergeServiceFiles()
}

tasks.named('jar') {
    enabled = false
}

tasks.named('build') {
    dependsOn tasks.named('shadowJar')
}

tasks.named('startScripts') {
    dependsOn tasks.named('shadowJar')
    classpath = files(tasks.named('shadowJar').get().archiveFile)
}

tasks.named('distZip') {
    enabled = false
}

tasks.named('distTar') {
    enabled = false
}

tasks.named('shadowDistZip') {
    enabled = false
}

tasks.named('shadowDistTar') {
    enabled = false
}

test {
    useJUnitPlatform()
}
"@
    $gradlePath = Join-Path $OutputPath "build.gradle"
    $gradle | Out-File -FilePath $gradlePath -Encoding UTF8
    Write-ReportItem "Generated" "build.gradle ($($report.dependencies.Count) dependencies)" "Green"

    # README.md is produced by the write-readme skill (run after Step wiring) — not generated here.

    # --- Copy PowerShell scripts ---
    if ($report.powerShellScripts.Count -gt 0) {
        $scriptsDir = Join-Path $resourcesDir "scripts"
        New-Item -ItemType Directory -Force -Path $scriptsDir | Out-Null
        $wfScriptsDir = Join-Path $bcbDir "src\main\resources"
        foreach ($script in $report.powerShellScripts) {
            $srcScript = Get-ChildItem -Path $wfScriptsDir -Filter $script -Recurse | Select-Object -First 1
            if ($srcScript) {
                Copy-Item $srcScript.FullName $scriptsDir
                Write-ReportItem "Copied" $script "Green"
            }
        }
    }

    # --- Manual Task files ---
    if ($hasMt) {
        # MT detected: generate actions/<name>.js skeletons from the ShadowCore template
        # (FreeMarker .html is intentionally NOT copied — incompatible with Sherpa).
        # WF mt/*.js copied to resources/mt for reference only.
        $actionsDir = Join-Path $resourcesDir "actions"
        New-Item -ItemType Directory -Force -Path $actionsDir | Out-Null
        $actionTemplate = Get-Content "$PSScriptRoot\action_js_template.txt" -Encoding UTF8 -Raw -ErrorAction SilentlyContinue
        if (-not $actionTemplate) { throw "action_js_template.txt not found in $PSScriptRoot. Update wf-migrate skill." }
        foreach ($mt in $report.manualTasks) {
            # Tag values must match the ProcessDataKeys MT_*_PENDING_TAG / FINAL_TAG
            # defaults so checkAndMarkLastTask marks the tag the sender actually set.
            $js = $actionTemplate `
                -replace '\{MT_TITLE\}',   $mt.name `
                -replace '\{MT_NUMBER\}',   $mt.mtNumber `
                -replace '\{QUEUE_NAME\}', $mtQueueName `
                -replace '\{PENDING_TAG\}', 'pending' `
                -replace '\{FINAL_TAG\}',   'reviewed'
            $jsPath = Join-Path $actionsDir "$($mt.name).js"
            $js | Out-File -FilePath $jsPath -Encoding UTF8
            Write-ReportItem "Generated" "actions/$($mt.name).js" "Green"
        }
        $mtRefDir = Join-Path $resourcesDir "mt"
        New-Item -ItemType Directory -Force -Path $mtRefDir | Out-Null
        foreach ($mt in $report.manualTasks) {
            $srcDir = Join-Path $bcbDir "src\main\resources\mt\$($mt.folder)"
            foreach ($js in @(Get-ChildItem -Path $srcDir -Filter "*.js" -ErrorAction SilentlyContinue)) {
                Copy-Item $js.FullName $mtRefDir -Force
            }
        }
    } elseif ($report.manualTaskFiles.Count -gt 0) {
        # Legacy non-MT flat copy — unchanged.
        $mtOutDir = Join-Path $resourcesDir "mt"
        New-Item -ItemType Directory -Force -Path $mtOutDir | Out-Null
        $wfMtDir = Join-Path $bcbDir "src\main\resources\mt"
        foreach ($mt in $report.manualTaskFiles) {
            $srcMt = Get-ChildItem -Path $wfMtDir -Filter $mt | Select-Object -First 1
            if ($srcMt) {
                Copy-Item $srcMt.FullName $mtOutDir
                Write-ReportItem "Copied" $mt "Green"
            }
        }
    }

    Write-ReportItem "Output Directory" $OutputPath "Cyan"
}

# === GENERATE DESIGNER FILES ===
if ($GenerateCode -or $GenerateDesignerFiles) {
    if (-not $OutputPath) {
        $parent = (Get-Item $WfProcessPath).Parent.FullName
        $OutputPath = Join-Path $parent "sherpa-generated\$SherpaProjectName"
    }
    if (-not $RpaSuitePath) {
        $RpaSuitePath = (Get-Location).Path
    }

    # Mandatory version check before generating Designer metadata
    $versionOk = Test-DesignerVersion -RpaSuiteDir $RpaSuitePath
    if (-not $versionOk) {
        Write-ReportItem "Designer Files" "SKIPPED due to version mismatch — update wf-migrate skill" "Red"
        $report.errors += "Designer files were NOT generated. Version mismatch detected. Update ExpectedProductVersion and ExpectedDesignerExeVersion in wf-migrate.ps1."
    } else {
        if ($hasMt) {
            # MT diagram blocks are built from $manualTasks inside Build-DesignerProcessFile
            # (Prepare/Save pairs). $stepNames here mirrors the Java step classes (Prepare/Save
            # pairs + generic steps for any non-MT processor) for reporting only.
            $stepNames = @()
            foreach ($mt in $report.manualTasks) {
                $stepNames += "Prepare$($mt.stepSuffix)Step"
                $stepNames += "Save$($mt.stepSuffix)Step"
            }
            foreach ($proc in $report.processors) {
                $stepName = "${proc}Step"
                if ($stepNames -notcontains $stepName) { $stepNames += $stepName }
            }
            New-SherpaDesignerFiles -ProjectDir $OutputPath -ProjectName $SherpaProjectName -PackageName $PackageName -RpaSuiteDir $RpaSuitePath -DesignerProjectName $DesignerProjectName -StepNames $stepNames -InitParamsAsset $InitParamsAsset -EmailTemplatesAsset $EmailTemplatesAsset -StepArgs $StepArgs -hasMt -manualTasks $report.manualTasks -mtQueueName $mtQueueName
        } else {
            $procNames = @($report.processors)
            if ($procNames.Count -eq 0) {
                # No Java processor/ directory in the WF source — fall back to the
                # processor names parsed from the XML configs' Groovy imports so the
                # flat diagram still gets one Step block per processor instead of an
                # empty Start+End diagram.
                $procNames = $report.steps |
                    Where-Object { $_.processor } |
                    ForEach-Object { $_.processor } |
                    Select-Object -Unique
            }
            $stepNames = $procNames | ForEach-Object { "${_}Step" }
            New-SherpaDesignerFiles -ProjectDir $OutputPath -ProjectName $SherpaProjectName -PackageName $PackageName -RpaSuiteDir $RpaSuitePath -DesignerProjectName $DesignerProjectName -StepNames $stepNames -InitParamsAsset $InitParamsAsset -EmailTemplatesAsset $EmailTemplatesAsset -StepArgs $StepArgs
        }
    }
}

# === 7. SUMMARY ===
Write-ReportHeader "Migration Summary"
Write-ReportItem "Process Type" (($report.steps | ForEach-Object { $_.type } | Select-Object -Unique) -join ", ") "Cyan"
Write-ReportItem "Steps to Create" $report.steps.Count "Green"
Write-ReportItem "Processors" ($report.processors -join ", ") "Yellow"
Write-ReportItem "InitParams Fields" $report.initParams.Count "Green"
Write-ReportItem "DataKeys" $report.dataKeys.Count "Green"
if ($hasMt) { Write-ReportItem "Manual Tasks" $report.manualTasks.Count "Magenta" }

if ($report.warnings.Count -gt 0) {
    Write-ReportHeader "Warnings"
    foreach ($w in $report.warnings) { Write-Host "  ⚠ $w" -ForegroundColor Yellow }
}
if ($report.errors.Count -gt 0) {
    Write-ReportHeader "Errors"
    foreach ($e in $report.errors) { Write-Host "  ✗ $e" -ForegroundColor Red }
}

# === 8. OUTPUT JSON REPORT ===
Write-ReportHeader "JSON Report (for Claude Code)"
$jsonReport = $report | ConvertTo-Json -Depth 5
Write-Host $jsonReport -ForegroundColor DarkGray
$reportFile = Join-Path (Get-Location) "wf-migrate-report.json"
$jsonReport | Out-File -FilePath $reportFile -Encoding UTF8
Write-ReportItem "Report Saved" $reportFile "Green"

Write-Host "`n=== Analysis Complete ===" -ForegroundColor Cyan
if ($GenerateCode) {
    Write-Host "Generated Sherpa project files in: $OutputPath" -ForegroundColor Green
} else {
    Write-Host "Use this report with Claude Code /wf-migrate skill" -ForegroundColor Green
}
