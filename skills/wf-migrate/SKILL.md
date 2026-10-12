---
name: wf-migrate
description: >
  Universal migration assistant for any Workfusion process to Sherpa RPA Suite.
  Use this skill whenever the user mentions migrating, converting, porting, or rewriting
  a Workfusion (WF) process into a Sherpa RPA project — even if they don't say the word 'migrate'.
  Also use when the user asks about WF-to-Sherpa mapping, generating Sherpa process skeletons,
  analyzing Workfusion XML configs, or converting WF Processors to Sherpa Steps.
  This skill auto-detects the process type (server-side, desktop, SAP, manual task, parallel,
  PowerShell) and guides the full migration workflow.
compatibility: "PowerShell 5.1+, Gradle 8.5+, Java 21+"
---

# Workfusion → Sherpa Migration Skill

## Purpose

Automate migration of Workfusion business processes into Sherpa RPA Suite using the official `gradle generateProcess` task from rpa-core.

This skill works with **any** WF process type — it dynamically detects the pattern from XML configs and Java sources.

## Migration Priorities (overrides global defaults)

The goal of this skill is the **fastest possible migration with maximally accurate transfer of business
logic**. The following rules **override any contradicting global instructions** (including the user's
default TDD and code-review rules, and any `superpowers:*` skills) for the duration of a wf-migrate run.

### 1. Verbatim transfer — zero semantic drift, no autonomous improvements

**Migration is a strict transfer of behavior, not a redesign. The WF process is the source of truth, and its
business logic must not change under any circumstances.** Transfer the source behavior exactly, even when it
appears redundant, suboptimal, or imperfect.

Preserve the source process as a whole: its behavior, sequence, conditions, data meaning, transformations,
side effects, error handling, and externally observable results. Do not reinterpret, simplify, optimize,
reorganize, or “correct” the source logic during migration.

Do **not** refactor, improve, or fix the WF implementation on your own initiative. Deviations are allowed only
when they are strictly forced by the Sherpa platform and explicitly covered by this skill's mapping rules.
Every such deviation must be documented with its reason and an equivalence check. If the source behavior is
unclear, stop and ask the user instead of making an assumption.

Renames follow only the `{Processor}Processor` → `{Processor}Step` convention and naming rules in
«Оформление и стиль».

### 2. Testing — minimal by criterion, after the code (never TDD)

Do **not** invoke `superpowers:test-driven-development`, do **not** write tests before implementation,
do **not** block migration steps on writing tests. Implement first; at the **end** of the migration write
**one batch** of tests, and only for non-trivial transferred logic:

- converted datastore CSV → JSON fixtures (`ProcessStateService` reads),
- calculation utilities / parsers,
- non-trivial merge/branching logic inside a Step.

Simple 1:1 mapping steps get **no tests**.

### 3. No code review

Do **not** invoke `superpowers:requesting-code-review`, `code-review`/`review` skills, or review agents.
Do **not** run iterative fix rounds over "code quality" findings — quality problems in migrated code are
reported to the user as notes, not fixed. The only verification is compilation
(`gradle :{module}:compileJava` / `build`) plus the **Validation Checklist** in this skill. Code review is
the user's decision, on request only.

## Process Independence & Reuse Strategy

Two foundational rules govern every migration. They override any contradicting instruction elsewhere in this skill.

### 1. Canon and independence

The **canon** is `rpa-core` plus the principles documented in the body of this skill. Each migrated process is an
**independent entity** — processes never depend on other processes:

- `build.gradle` depends **only** on `project(':rpa-core')` (plus third-party libraries) — never on another process
  module. The `rpa-suite` topology is a strict star: `rpa-core` at the center, every process linked only to it.
- **Forbidden:** importing another process's Java package, and **modifying any existing process** during a migration.
  Sibling processes are read for inspiration only — never edited, never linked, never copied by name.
- The skeleton is created **only** via `gradle generateProcess` from `rpa-core`.

Past implementations matter **only as a source of principles** for working with specific technologies (WF/Sherpa
platform features) — not as a target to copy structure or names from.

### 2. Freshest Reference Discovery (for platform questions the canon doesn't cover)

When a platform-specific question is **not** covered by the canon (`.process` diagram shape, MT mechanics, `.sherpa`
schema, Orchestrator API, CSV→JSON fixtures, etc.), consult the freshest **merged** process — never a hardcoded
etalon. Freshness is a recency signal, not a quality signal, so a master gate is mandatory:

1. Enumerate sibling process modules in `rpa-suite` (exclude `rpa-core` and the process being migrated right now).
2. **Master gate** — keep only processes present on the default branch (`master`): verify with
   `git log -1 --format=%ci master -- <module>` (returns a commit). This excludes feature branches carrying
   unreviewed/unfinished patterns — a one-day-old WIP process is **not** a reference.
3. Rank the survivors by last commit date on `master`, newest first.
4. Match the target technology by the detection heuristics in Phase 2 (`build.gradle` deps + service classes +
   resources; the keyword→technology map, **not** process names).
5. **Validate** the found pattern against `rpa-core` — `rpa-core` wins on conflict; a sibling may carry a local
   deviation that must not propagate.
6. Extract the **principle only**; never copy names/structure and never introduce a cross-process dependency.
7. Degenerate case: if the only matching process is the one being migrated, rely on the canon in this skill and
   `rpa-core` — not on the in-progress work itself.

## When to trigger

- User asks to migrate / convert / port / rewrite a Workfusion process to Sherpa
- User mentions WF-to-Sherpa, Workfusion-to-Sherpa, or legacy RPA migration
- User wants to create a Sherpa project equivalent to an existing WF process
- User asks about mapping WF Processors to Sherpa Steps
- User needs to analyze a WF `.process` or XML config directory
- User mentions `gradle generateProcess` in context of WF migration
- User asks about converting WF `AppInitParams`, `AppTransaction`, `AppDoc` to Sherpa equivalents

## Supported process types (auto-detected)

| WF pattern | XML indicator | Sherpa equivalent |
|---|---|---|
| Server-side | Only `<script>`, no `<robotics-flow>` | Standard Step class |
| Desktop RPA | `<robotics-flow>` with `driver="desktop"` | Step + RPA libraries |
| SAP | `<robotics-flow fleet="SAP">` | Step + `rpa-sapgui` + `jacob.jar` |
| Manual Task | `mt.html`, `mt.js` in `resources/mt/` | MT Step (if supported) |
| Parallel | `<pool>` + `<list>` elements | Parallel Stream Steps |
| PowerShell | `.ps1` files in `resources/` | `jPowerShell` + `resources/scripts/` |

## Workflow

### Phase 1: Context Discovery

Determine before starting:
1. **WF source path** — directory containing the WF `*-bcb` module (with XML configs, Java sources)
2. **Sherpa rpa-suite path** — directory containing `rpa-core` (use current working directory or ask)
3. **Process name** — desired Sherpa project name in kebab-case (e.g., `my-new-process`). Название следует правилам раздела «Оформление и стиль»: lowercase, слова через `-`, номер контроля без дефиса (`icsNNNNN`).
4. **Designer project name** (optional) — human-readable name for Sherpa Designer files (e.g., `Мой процесс Описание`). If not provided, falls back to the technical process name. Имена `.sherpa`/`.process` — по правилам раздела «Оформление и стиль» (название из документации БП, напр. `ICS-NNNNN.sherpa`).

If the user only provides a WF path, auto-detect the process name from the directory name.

> **Important:** The `.sherpa` and `.sherpax` filenames use the **Designer project name** (human-readable), while the directory name uses the technical kebab-case name. Ask the user explicitly if they want a different display name for Designer.

### Phase 2: Dynamic WF Analysis

Use the bundled PowerShell analyzer to scan the WF process:

```powershell
# Run the analyzer
.\scripts\wf-migrate.ps1 -WfProcessPath "C:\path\to\wf\process" -SherpaProjectName "my-process"

# With a custom Designer display name
.\scripts\wf-migrate.ps1 -WfProcessPath "C:\path\to\wf\process" -SherpaProjectName "my-process" -DesignerProjectName "Мой процесс Описание" -GenerateDesignerFiles
```

The analyzer produces a JSON report (`wf-migrate-report.json`) with:
- List of XML configs with detected step types
- Processor class names mapped to Sherpa Step names
- Detected services (Email, AD, SAP, Jira, DB, etc.)
- Recommended `build.gradle` dependencies
- AppInitParams fields for `InitParameters.java`
- AppDoc / AppTransaction constants for `ProcessDataKeys.java`
- PowerShell scripts and Manual Task files found

#### Manual analysis fallback (if PowerShell unavailable)

```
1. Find XML configs in {process}-bcb/src/main/resources/configs/main/
2. For each XML determine step type:
   - <script> only → server-side
   - <robotics-flow> + driver="desktop" → desktop
   - <robotics-flow> + fleet="SAP" → sap
   - <pool> + <list> → parallel
3. Extract Processor class from Groovy script imports:
   - Pattern: import by.a1.{pkg}.processor.{Name}Processor → {Name}Step
4. Scan for .ps1 files (PowerShell), mt.html (Manual Task)
5. Read AppInitParams.java → fields for InitParameters
6. Read AppDoc.java / AppTransaction.java → constants for ProcessDataKeys
7. Read every Processor/Supplier class completely and record exact control flow, operation order, comparators, and data-selection semantics before generating target code.
8. Read Processor classes → detect services by import keywords:
   - email/mail/smtp/imap → rpa-email
   - ad/ldap/ADService → rpa-ad
   - sap/SAP/SapGui/RobotDriver → rpa-sapgui + jacob.jar
   - jira/JIRA/Jsd → rpa-jira
   - sharepoint/SharePoint → rpa-sharepoint
   - sql/jdbc/mssql/sqlserver → mssql-jdbc
   - oracle/ojdbc → ojdbc11 + orai18n
   - powershell/jPowerShell → jPowerShell
   - excel/poi/poiji/xlsx → poiji
   - okhttp/httpclient/rest → okhttp + logging-interceptor
   - jsoup/html → jsoup
```

### Phase 3: Dependency Mapping

Build the `build.gradle` dependency list based on detected services:

**Always included:**
- `implementation project(':rpa-core')`
- `compileOnly 'org.projectlombok:lombok:1.18.40'` + annotation processor
- JUnit 5 + Mockito for tests

**Conditionally add:**

| Detected | Dependency |
|---|---|
| Active Directory | `rpa-ad` |
| SAP GUI | `rpa-sapgui` + `files('libs/jacob.jar')` |
| Jira/JSD | `rpa-jira` |
| SharePoint | `rpa-sharepoint` |
| MS SQL Server | `com.microsoft.sqlserver:mssql-jdbc:12.6.1.jre11` |
| Oracle DB | `com.oracle.database.jdbc:ojdbc11:21.9.0.0` + `com.oracle.database.nls:orai18n:21.9.0.0` |
| PowerShell | `com.profesorfalken:jPowerShell:3.1.1` |
| Excel | `com.github.ozlerhakan:poiji:5.2.0` |
| HTTP/REST | `com.squareup.okhttp3:okhttp` + `com.squareup.okhttp3:logging-interceptor` |
| HTML parsing | `org.jsoup:jsoup:1.21.2` |

**Запрет перехода на v2-библиотеки.** В рамках миграции не переводите зависимости на major version 2 и не заменяйте текущий артефакт или координату из карты зависимостей на v2-аналог. Сохраняйте координаты и версии из карты выше и канона `rpa-core`; транзитивные версии не изменяйте вручную. Если для совместимости Sherpa требуется v2, остановите миграцию и запросите явное решение пользователя. Это правило относится только к библиотечным координатам и версиям и не ограничивает версию процесса, `ProductVersion`/Designer, `project(':rpa-core')` или транзитивные зависимости вне прямого контроля миграции.

### Phase 4: Generate Sherpa Project

Official generation command:
```bash
cd {rpa-suite-directory}
gradle generateProcess -PprocessName={process-name}
```

This creates the standard skeleton with:
- `InitParameters.java` (with `EmailRecipients` — mandatory!)
- `ProcessTransaction.java`
- `ProcessDataKeys.java`
- Example Step classes
- Email templates, init params JSON, `process-config.json`, `logback.xml`
- `README.md`

### Phase 5: Modify Generated Project

After generation, apply changes from the analysis report:

1. **Update `build.gradle`** — add detected dependencies
2. **Update `InitParameters.java`** — add fields from WF `AppInitParams` (never remove `EmailRecipients`!)
3. **Update `ProcessDataKeys.java`** — add constants from WF `AppDoc.Column` / `AppTransaction.Column`
4. **Update `ProcessTransaction.java`** — add `get`/`set` methods for all data keys (use Gson for JSON serialization)
5. **Create Step classes** — one per WF Processor:
   - Name pattern: `{ProcessorName}Processor` → `{ProcessorName}Step`
   - Annotate: `@StepName("{ProcessorName}Step")` — the `@StepName` value **must equal the class name** so the runtime step name, the Java class, and the Designer block `StepName` are identical
   - Implement: `execute(Transaction transaction, List<String> args)`
   - Inject required services based on Processor analysis
   - Copy business logic from `Processor.execute()` **verbatim in behavior** — see «Migration Priorities».
   - Before adapting APIs, create a line-by-line source-to-target trace and mark every external call, branch, loop, comparator, selected collection element, transformation, side effect, and exception boundary. The adaptation is complete only when this trace is equivalent.
   - Do not replace any source operation with a convenient alternative merely because it is shorter or compiles. In particular, preserve explicit `min/max`, sorting, filtering, and temporal ordering logic exactly.
6. **Create Service classes** — migrate from WF `service/` directory
7. **Create DTO/Model classes** — migrate from WF `dto/` directory
8. **Copy resources**:
   - PowerShell scripts → `src/main/resources/scripts/`
   - Email templates → convert from CSV to JSON if needed
   - Manual Task → `src/main/resources/mt/` (if platform supports it)
9. **Generate `README.md` via the `write-readme` skill.** `gradle generateProcess`
   lays down a placeholder `README.md` — overwrite it by running the skill
   **`write-readme`** against the process directory **after** the Step classes
   and `StepName` wiring in `.process` are done. The `write-readme` analyzer
   deterministically extracts `@StepName`, step order, `init_params`,
   `email_templates`, service variables **and the MT section** (forms
   `actions/*.js`, `*ActionLink` fields, Prepare/Save step pairs, `MT_<NN>_*`
   constants, Orchestrator-setup) straight from the code — do **not** hand-write
   the MT section. Do **not** reference another process by name in the new README.

### Phase 6: Validation

See the **Validation Checklist** section at the end of this document for the complete list.

### Phase 7: Generate Sherpa Designer Files

After the Java project is fully migrated, create the Sherpa Designer metadata files so the process can be opened and edited in Sherpa Designer.

**Required Designer files (only 3):**

| File | Format | Purpose |
|---|---|---|
| `{project}.sherpa` | JSON | Full project tree descriptor (all folders, source files, build artifacts) |
| `{project}.sherpax` | JSON | Workspace pointer (`ActiveProjectRelativePath`) |
| `Главная.process` | XML | Workflow diagram — non-MT: Start → Try/Catch → Steps → End + Try/Catch → HandleError → Прервать; MT: Start → Prepare* → ReceiveRobotTask → Switch/Case → Save* → End |

> **Note:** `.robot`, `__app.process`, and `__references.dat` are **NOT** needed for Designer to open/edit the diagram. They are generated later by the build/publish pipeline. Do **not** create them during migration.

**⚠️ Designer Version Check (MANDATORY)**

Sherpa Designer updates may change the `.sherpa` JSON schema or `.process` XML format. Validate version compatibility before generating these files.

```powershell
# Expected versions (update BOTH when Designer is updated)
$ExpectedProductVersion   = "1.4.4.39274"  # from .sherpa "ProductVersion"
$ExpectedDesignerExeVersion = "1.4.4.39274"  # from DiagramDesigner.exe FileVersion

# Check installed Designer
$designerExe = "C:\Program Files\Sherpa RPA\Designer\DiagramDesigner.exe"
if (Test-Path $designerExe) {
    $installed = (Get-Item $designerExe).VersionInfo.FileVersion
    if ($installed -ne $ExpectedDesignerExeVersion) {
        throw "Designer version mismatch! Expected $ExpectedDesignerExeVersion, found $installed. STOP migration and update the wf-migrate skill before continuing."
    }
}

# Check reference .sherpa ProductVersion (if a reference project exists in rpa-suite)
# Non-blocking: .sherpa ProductVersion varies per project and is bumped by Designer on
# save; the EXE version check above is the reliable gate for template compatibility.
$refSherpa = Get-ChildItem -Path $RpaSuitePath -Filter "*.sherpa" -Recurse | Select-Object -First 1
if ($refSherpa) {
    $refProduct = (Get-Content $refSherpa.FullName | ConvertFrom-Json).ProductVersion
    if ($refProduct -ne $ExpectedProductVersion) {
        Write-Warning "Reference .sherpa ProductVersion differs (expected $ExpectedProductVersion, found $refProduct). Non-blocking - continuing."
    }
}
```

If the installed **Designer EXE** version mismatches, **immediately stop the migration** and ask the user to update the skill. Do NOT generate `.sherpa` or `.process` files with outdated templates — they will be corrupted or unreadable in the current Designer. A difference in the reference `.sherpa` `ProductVersion` is **non-blocking** (warning only); that value varies per project and is bumped by Designer on save.

**Generating the files:**

> Имена файлов `.sherpa` и `.process`, а также папок — по правилам раздела «Оформление и стиль» (название из документации БП; несколько `.process` — через пробел с идентификатором; папки аналогично директориям Java-проекта).

1. **`.sherpa`** — Project tree JSON. Copy `References`, `Properties`, `Version`, `IsDarkTheme`, and `ProductVersion` from a reference `.sherpa` found via Freshest Reference Discovery. The folder tree is **optional metadata for Designer's project pane** — it is NOT required for the diagram to render steps. Step blocks resolve at runtime via their `StepName`/`StepsPath`/`JarPath` block properties (a working reference `.sherpa` ships with an empty `Folders` tree and still displays all steps). When building the tree:
   - Root folder (`RelativePath: ""`) contains `Главная.process` (`Main: true`, `Showing: true`).
   - Every subdirectory is represented recursively with its own `Folders`, `Files`, and `Links` arrays.
   - Excluded from the tree: `.sherpa`/`.sherpax` files, `.git/`, and build/backup output dirs (`build/`, `.backup/`, `.gradle/`, `out/`, `bin/`, `target/`).
   - Use PowerShell `ConvertTo-Json -Depth 100` and fix Unicode escapes for non-ASCII filenames (e.g. `Главная.process`).

2. **`.sherpax`** — Simple JSON pointing to the `.sherpa` file:
   ```json
   {"Version":"1.00","ActiveProjectRelativePath":"{project}.sherpa","Projects":[{"RelativePath":"{project}.sherpa"}]}
   ```

3. **`Главная.process`** — Full workflow diagram generated automatically from the detected WF Processors. The shape depends on whether the process has a Manual Task (MT):

   **Non-MT** — canonical diagram with error handling, **no queue block**:
   ```
   Старт → Try/Catch --Next→ Step₁ → Step₂ → … → Stepₙ → Конец
                Try/Catch --Error→ HandleError --Next→ Прервать
   ```
   - **Start** block (fixed ID, top of diagram) → **Try/Catch** → business Steps → **Конец** (`ReturnOrStop`).
   - **Error branch**: `Try/Catch` `Error`→`Input` → **HandleError** `Next`→`Input` → **Прервать** (`FullAbort`).
   - **One Java Step block per Processor** — both `DisplayName` and the **`StepName` property are set to `${ProcessorName}Step`** (the full Java class name, e.g. `PrepareAllStep`), which equals the `@StepName("${ProcessorName}Step")` value emitted by `New-GenericStepJava`. The runtime step name, the Java class, and the Designer block are thus identical for uniformity. The diagram `StepName` must match the step's runtime `@StepName` exactly — `StepRegistry.getStep` is case-sensitive, so any mismatch leaves the step unresolved at runtime. Blocks are spaced vertically by 200 px.
     - **SaveTransaction (`Сохранение транзакции`) is set `True` only on the FIRST step, `False` on all the rest.** Each `SaveTransaction=True` step calls `StorageCreateFile` under the same `transaction_<JobGuid>` name; multiple such steps in one run create duplicate Storage records and break `StorageReadFile` (`"Found more than 1 record"`).
     - **HandleError** has no `StepName` (it is not a Java step); the generator substitutes its `InitParamsAssetName`/`EmailTemplatesAssetName` properties (by Property Name) to reference the process's actual init-params / email-templates orchestrator assets — the skeleton template ships with mismatched placeholder asset names that the generator corrects.
   - **Connectors**: `Next → Input` along the main column; `Error → Input` (Try/Catch → HandleError) and `Next → Input` (HandleError → Прервать) on the error branch.

   **MT** — `Start → Prepare*Step → ReceiveRobotTask → Switch/Case → Save*Step → End` (see the «Designer `.process` для MT» section). MT Prepare/Save steps follow the **same naming rule as non-MT steps**: their `@StepName` is the full class name (e.g. `@StepName("PrepareAllStep")`), and the block `StepName`/`DisplayName` equal that same class name. For MT the sender (queue-task-creating) step must additionally be the one that saves — adjust manually after generation if the diagram is restructured into stages.

   > **Skeleton note:** the `gradle generateProcess` skeleton (`buildSrc/src/main/resources/Главная.process`) always contains an `OrchGetDefaultTask` block («Получить задачу по умолчанию») — it is needed **only for MT/queue-triggered processes** (the receiver stage reads a task from the queue). The skill's non-MT generator does **not** emit it. When manually editing the skeleton for a non-MT process, delete the `OrchGetDefaultTask` block and rewire `Try/Catch --Next→` directly to the first business Step.
   >
   > **⚠️ Also clear `Args` on every Java Step block.** The skeleton ships each Step block with `Args="$TaskGuid"` — a bare PowerShell variable that the `OrchGetDefaultTask` block populates for MT processes. Once you delete that block for a non-MT process, `$TaskGuid` is `$null` at runtime, the block's PowerShell wrapper evaluates `$Args=$TaskGuid;` → `$null`, and the next line `$Args.Replace('"','\"')` throws `You cannot call a method on a null-valued expression` (surfaced as `[UNHANDLED ERROR] …`). Set `Args=""` on every Step block — a working non-MT reference has zero `TaskGuid` references and all `Args` empty.
   >
   > **Automated repair:** after generating the Designer files, `New-SherpaDesignerFiles` runs `Repair-JavaStepArgs` — it scans every `*.process` in the project and clears `Args="$TaskGuid"` on Java Step blocks in any diagram that has **no** block assigning `$TaskGuid` (i.e. no queue receiver). Diagrams with a receiver keep the reference (legitimate MT pattern); the report shows a `Repaired`/`Checked` line per file. This also covers subprocess diagrams hand-copied from the skeleton. Note: the **published `.robot` artifact embeds stale diagram copies** — after fixing `.process` files, re-publish, or the error persists when running the bot.

   The script reads block templates from external files (must be kept next to `wf-migrate.ps1`):
   - `scripts/step_block_template.txt` — Content XML for a Java Step block (from a reference Designer project). Current template is **block `Version="495"`** (regenerated from a canonical Designer v495 block), which adds the `ConnectSAP` (Bool, default `False`) property and a refactored PowerShell `Code` body (Write-Log wrapper + SAP-connection branch) versus the prior v465 template. Sample property values used as `-replace` anchors by the script: `DisplayName="initOrder"`, `StepName="initOrder"`, `InitParamsAssetName="demo_init_params"`, `EmailTemplatesAssetName="demo_email_templates"`, `Args="ТЕСТ"`, `RetryDelayMs=1000`, `SaveTransaction=True` (first step).
   - `scripts/end_block_template.txt` — Content XML for an End block
   - `scripts/trycatch_block_template.txt` — Content XML for the Try/Catch block (`InternalName="TryCatchContainer"`); connectors `Next`, `Error`. Non-MT only.
   - `scripts/handleerror_block_template.txt` — Content XML for the HandleError block (`InternalName="MyBlock7be6…"`); no `StepName`. The generator substitutes `InitParamsAssetName`/`EmailTemplatesAssetName` by Property Name (the skeleton template's placeholder values are mismatched). Connectors `Input`, `Error`, `InputLeft`, `Next`. Non-MT only.
   - `scripts/fullabort_block_template.txt` — Content XML for the Прервать block (`InternalName="FullAbort"`); connectors `Input`, `InputLeft`. Non-MT only.

   > If these template files are missing, the migration script throws an error telling you to update the skill.

   > **Do not** add `.robot`, `__app.process`, or `__references.dat`. Designer creates them automatically during build/publish.

## Code Templates

### InitParameters (after modification)

```java
package by.a1.{pkg}.model;

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

  // ADD fields from WF AppInitParams below this line
}
```

### ProcessTransaction (after modification)

```java
package by.a1.{pkg}.transaction;

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
}
```

### Step Class (universal template)

```java
package by.a1.{pkg}.steps;

import by.a1.{pkg}.model.InitParameters;
import by.a1.{pkg}.transaction.ProcessTransaction;
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
@StepName("{StepName}Step")
public class {StepName}Step implements Step {

  private final OrchestratorService orchestratorService;

  @Inject
  public {StepName}Step(OrchestratorService orchestratorService) {
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

    // BUSINESS LOGIC HERE (adapted from WF Processor)

    log.info("Finish {}.execute()", className);
  }
}
```

## Оформление и стиль (Naming & Style Conventions)

Источник: [«Оформление и стиль»](https://wiki.a1.by/spaces/SRPA/pages/453837503) (SRPA). Эти правила
применяются ко всем артефактам миграции — Java-проекту, файлам Designer, ресурсам Orchestrator.
Соблюдайте их с первого шага (Phase 1) и проверяйте в Validation Checklist.

### Java

- **Название проекта** — с маленькой буквы, латиница и цифры, слова через дефис `-`. Номер контроля
  пишется **без дефиса (напр. `icsNNNNN`)**. Техническое имя проекта в kebab-case из Phase 1 уже
  соответствует этому правилу.
- **Код** — придерживаемся Google Java Style; рекомендуется плагин IDE `google-java-format` (дистрибутив
  для ручной установки — `\\MAIN.VELCOM.BY\VelcomGroups\BPD\RPA\NEW RPA platform\Sherpa RPA\Настройка рабочего места\IDEA 2024.1.4`).
- **Прочие файлы** — файлы ресурсов, которые пойдут в Orchestrator как текстовые ассеты, именуем по
  правилам ассетов (см. ниже, `_`-разделитель). Остальные файлы — так, чтобы был понятен смысл, остальное
  на выбор разработчика.

### Sherpa Designer

- **`.sherpa`** — название рекомендуется как в документации бизнес-процесса либо сокращённая версия
  (для «`ICS-NNNNN. <название БП>`» → `ICS-NNNNN.sherpa`; при необходимости сохранить
  идентификатор — `ICS-NNNNN (<название БП>).sherpa`).
- **`.process`** (схемы блоков):
  - если файл один — аналогично `.sherpa`;
  - если файлов несколько — `<имя .process> <личный идентификатор>` через пробел (напр. основная схема
    `ICS-NNNNN.process`, схема подпроцесса `ICS-NNNNN <идентификатор>.process`).
- **Папки** — желательно именовать аналогично директориям Java-проекта.

### Sherpa Orchestrator

#### Процессы (Processes)

- **Название** — соответствует названию бизнес-процесса в документации либо сокращённой версии
  (содержит номер контроля либо аббревиатуру + доп. идентификаторы при необходимости).
- **Версия**:
  - начинаем с **0.1.0** и далее наращиваем с учётом веса изменения (major.minor.patch);
  - на тестовом оркестраторе допустимы отклонения и пометки (`_ver1` и т.п.); релизная версия на проде
    должна содержать только номер;
  - первая **релизная** версия должна быть **1.0.0**.

#### Ресурсы (Assets)

- с маленькой буквы, латиница и цифры, слова через подчёркивание `_`; номер контроля без дефиса
  (напр. `icsNNNNN_init_params`).
- Применяется к именам ассетов в `ProcessDataKeys` (`*_ASSET_NAME`) и к файлам ресурсов, которые
  пойдут в Orchestrator как текстовые ассеты.

#### Триггеры (Triggers)

- **Название** — составляется из названия процесса + идентификатора частоты/источника запусков
  (напр. `ICS-NNNNN Daily`, `APR Hourly`, `ICS-NNNNN Each-15-minutes`,
  `ICS-NNNNN_AD_Password_reset Email-driven`, `ICS-NNNNN Monthly`, `ICS-NNNNN Jan|May`). Подробнее —
  [RPA-333](https://jira.a1.by/browse/RPA-333).
- **Описание** — рекомендуется, если запуски по триггеру не очевидным образом привязаны к событиям,
  которые триггер напрямую не отслеживает (напр. «Запускается по мере появления задач, создаваемых
  процессом ANM-Manual»).

#### Роли (Roles)

- соответствует названию роли MIM.

### Git

Нейминг веток/MR и прочего — в отдельной статье (см. `CommitMessageConvention.md` и «Работа с Git»
на wiki.a1.by).

## WF → Sherpa Concept Mapping

| Workfusion | Sherpa |
|---|---|
| `<pool>` with `<list>` | `ProcessTransaction` + parallel streams |
| `<robotics-flow>` + `driver="desktop"` | `Step` with `@StepName` |
| `AppFactory.init(binding)` | `OrchestratorService` + `Transaction` |
| `AppTransaction` | `ProcessTransaction` wrapper |
| `AppDoc.Column.DOC_WORKFLOW_STATUS` | `ProcessDataKeys.WORKFLOW_STATUS` |
| `{Name}Processor.class` | `{Name}Step` class |
| `ErrorUtils.errorHandler` | `try/catch` + logging |
| `DataStore` | `Orchestrator Assets` (текстовые ассеты для JSON-состояния) |
| `S3` | `Orchestrator Storage` (`orchestratorService.files()`) |
| `AppInitParams` | `InitParameters` (Lombok `@Getter`) |
| `@AnnInitParamField(key = "...")` | Direct fields in `InitParameters` |

### Datastore (JDBC → Orchestrator Assets)

В среде **Sherpa нет Datastore** (ни WF DatastorePluginAdapter, ни локальных таблиц БД для шагов).
Вместо JDBC/`DataSource` используйте **текстовые ассеты оркестратора** для хранения JSON-состояния:

```java
// Чтение
Asset asset = orchestratorService.assets().get("my_process_state").execute();
List<MyEntity> items = gson.fromJson(asset.asString(), new TypeToken<List<MyEntity>>() {}.getType());

// Запись
String json = gson.toJson(items);
orchestratorService.assets().update("my_process_state").text(json).execute();
```

**Важно:**
- Удалите `mssql-jdbc`, `ojdbc` и другие JDBC-драйверы из `build.gradle`.
- Удалите классы `DataSourceFactory`, `*Datastore`.
- Создайте ассеты заранее (тип **Text**) или проверяйте `assets().exists(name)` перед чтением.
- Для больших объёмов данных используйте Orchestrator Storage (`files()`), а не ассеты.

### Datastore CSV-фикстуры → JSON-фикстуры тестов

WF хранит тестовые данные datastore-ов в `{process}-bcb/src/test/resources/datastores/*.csv`.
Формат специфичный: **один CSV = один datastore**, одна колонка (заголовок = имя колонки),
одна строка данных, значение которой — **JSON-массив, экранированный по правилам CSV**
(каждая `"` внутри поля удвоена в `""`). Пример:

```csv
"accounts"
"[{""accountNumber"":""62440100"",""accountText"":""Расходы..."",...}]"
```

На Sherpa нет datastore и нет CSV-фикстур: `ProcessStateService` читает те же данные из
**текстовых ассетов** оркестратора как `List<T>` / `Set<String>` (Gson `TypeToken`). Для
unit-тестов Step-ов эти данные нужны как **входные JSON-фикстуры** по паттерну
`getResourceAsStream` + `Gson.fromJson` + AssertJ/JUnit5 (единственный существующий паттерн
в rpa-suite; эталон — `rpa-core/src/test/java/by/a1/rpa/currencyrates/CurrencyRatesTest.java`
и `rpa-core/src/test/resources/currencyrates/test/currency_rates_config.json`).

**Когда применять:**
- В WF-модуле есть `src/test/resources/datastores/*.csv` (не путать с `input_data.csv` —
  это BP input transaction → init params, отдельный случай, см. Phase 5).
- На Sherpa Step читает данные через `ProcessStateService` из ассетов, и нужны unit-тесты
  этого Step с детерминированными входными данными.

**Процесс миграции:**

1. **Идентифицировать CSV.** Заголовок (первая строка) = имя колонки datastore (`comments`,
   `accounts`, ...). Единственная строка данных содержит JSON-массив.
2. **Определить Sherpa-тип.** Посмотреть `ProcessStateService` (или WF `*Datastore`):
   `List<Entity>` или `Set<String>`. Имена полей JSON должны совпадать с `@SerializedName`
   в Sherpa-сущности (есть альтернативные имена — сохраняйте primary; напр. `accountText`
   при альтернативе `accountName`).
3. **Конвертировать CSV → JSON.** Содержимое ячейки — уже валидный JSON, экранированный по
   правилам CSV. Распаковка однозначна для валидного JSON (нет двух смежных неэкранированных
   `"`):
   - отбросить обрамляющие `"` поля;
   - заменить `""` → `"`;
   - `JSON.parse` (round-trip = валидация распаковки);
   - `JSON.stringify(obj, null, 2)` (pretty-print, отступ 2);
   - писать как **UTF-8 без BOM**, кириллицу — literal (не `\uXXXX`).
4. **Разместить** в `src/test/resources/<feature>/<env>/<name>.json` (конвенция rpa-core
   `<feature>/<env>/`, напр. `<feature>/test/<feature>_accounts.json`). **Не** в `datastores/`
   — это WF-концепция, на Sherpa её нет. При необходимости добавить параллельный
   `<feature>/prod/` набор (как `currencyrates/prod/`).
5. **Проверить:**
   - round-trip `JSON.parse` (валидность);
   - количество элементов массива;
   - идентичность набора ключей во всех объектах массива;
   - кодировка UTF-8 без BOM;
   - совместимость имён полей с `@SerializedName` Sherpa-сущности.
6. **Использовать в тесте:**
   ```java
   try (Reader reader = new InputStreamReader(
       Objects.requireNonNull(
           getClass().getClassLoader().getResourceAsStream("<feature>/test/<feature>_accounts.json")),
       StandardCharsets.UTF_8)) {
     List<Account> accounts = new Gson().fromJson(reader, new TypeToken<List<Account>>() {}.getType());
     assertThat(accounts).hasSize(411);
   }
   ```

**Нюансы:**
- Если CSV содержит **несколько колонок** (напр. `<feature>_accounts_common.csv` с
  `emails_to, emails_copy, s3_bucket_name, ...`) — это не «JSON-в-ячейке», а обычная табличная
  CSV. Каждый такой файл → JSON-объект (одна запись) или массив; маппинг полей по заголовкам.
- `input_data.csv` → не datastore, а init params → `*_init_params.json` (покрыто в Phase 5).
- Ручная транскрипция больших массивов (сотни объектов) исключена — используйте скрипт
  конвертации (Node `JSON.parse`/`stringify` round-trip, либо PowerShell `Import-Csv` +
  `ConvertFrom-Json`/`ConvertTo-Json -Depth 100` с контролем UTF-8/BOM). Временный скрипт
  удаляйте после конвертации.

**Конкретный пример:** поищите через Freshest Reference Discovery самый свежий merged-to-master процесс
в `rpa-suite`, у которого есть конвертированные datastore CSV→JSON фикстуры, и сверьте результат с
канонической процедурой выше. Не копируйте имена файлов/пакетов чужого процесса — применяйте процедуру
к собственным datastore-ам мигрируемого процесса.

### Файловое хранилище (S3 → Orchestrator Storage)

В среде **Sherpa нет S3**. Вместо прямого доступа к S3 используйте **Orchestrator Storage** через
`OrchestratorService`. При миграции отдельно определите папку Storage и имя файла: папка не является
частью имени иерархического пути.

```java
private static final String STORAGE_FOLDER = "ICS-60112";

// Имя — только basename, без '/' и '\\'. Папки SharePoint и локального staging сюда не переносятся.
String fileName = report.getName();
orchestratorService.files()
    .upload()
    .name(fileName)
    .folder(STORAGE_FOLDER)
    .fileName(fileName)
    .fromPath(Path.of("/local/path/file.xlsx"))
    .execute();

// exists/update/download используют то же плоское имя.
if (orchestratorService.files().exists(fileName).execute()) {
  orchestratorService.files()
      .update(fileName)
      .folder(STORAGE_FOLDER)
      .fileName(fileName)
      .fromPath(Path.of("/local/path/file.xlsx"))
      .execute();
}
orchestratorService.files()
    .download(fileName)
    .to(Path.of("/local/path/file.xlsx"))
    .execute();
```

Правила миграции:

- Сопоставьте S3 bucket/key prefix с отдельной папкой Orchestrator Storage и зафиксируйте это решение
  в плане миграции. Если API развёртывания ожидает GUID папки (`folderGuid`), укажите GUID для выбранной
  папки; не подставляйте SharePoint-путь или составное имя.
- В `.name(...)`, `exists(...)`, `update(...)` и `download(...)` передавайте только одно и то же имя файла;
  значения с `/`, `\\`, timestamp-папками или `SharePointFolder.name()` запрещены.
- Транзакционные файлы и бизнес-файлы должны иметь разные явно документированные папки. Фиксированная
  папка `transactions` используется только runtime для файлов транзакций; это не общее правило для
  бизнес-отчётов.
- Для процесса ICS-60112 бизнес-файлы должны находиться в папке с именем ровно `ICS-60112`, без вложенной
  иерархии. SharePoint может при этом использовать собственные папки по датам и подпроцессам.
- При генерации кода проверьте, что операции создания, обновления, проверки существования и скачивания
  используют один контракт папки/плоского имени.

**Не добавляйте** `aws-java-sdk-s3` в `build.gradle`.

### Supplier → Step Mapping

Каждый WF "supplier" (groovy-скрипт, инициализирующий переменные и отправляющий email в начале bot task) становится отдельным Sherpa `Step`. **Никогда не поглощать логику Supplier в другой Step** — каждый Supplier получает свой собственный Step-класс.

| WF Pattern | Sherpa Equivalent |
|---|---|
| `{Name}Supplier` | `{Name}Step` с `@StepName("{Name}Step")` |
| `{Name}Processor` | `{Name}Step` с `@StepName("{Name}Step")` |

Типичные ответственности Supplier и их Sherpa-маппинг:
- **Извлечение init params** → `Step.execute()` читает `transaction.getInitParameters(InitParameters.class)`
- **Расчёт отчётного периода** → Utility-класс (`ReportingPeriodCalculator` или аналог), вызываемый из Step
- **Email о начале работы** → `AppNotificationService.notificationWorkStart()`, вызываемый из Step
- **Чтение DataStore** → `ProcessStateService`, вызываемый из Step
- **Инициализация переменных** → типизированные setters в `ProcessTransaction`

### ProcessStateService — обёртка для Orchestrator Assets

DataStore-таблицы WF становятся **текстовыми ассетами Orchestrator** для хранения JSON. Создайте `ProcessStateService` для каждого процесса, инкапсулирующий чтение/запись ассетов:

```java
@Slf4j
public class ProcessStateService {
  private static final String MY_ENTITY_ASSET_NAME = "{process_id}_my_entity";
  private final OrchestratorService orchestratorService;
  private final Gson gson;

  // READ — проверка exists, затем get, возврат пустой коллекции при отсутствии
  public List<MyEntity> selectEntities() {
    try {
      if (!orchestratorService.assets().exists(MY_ENTITY_ASSET_NAME).execute()) {
        return List.of();
      }
      Asset asset = orchestratorService.assets().get(MY_ENTITY_ASSET_NAME).execute();
      String json = asset.asString();
      if (json == null || json.isBlank()) { return List.of(); }
      return gson.fromJson(json, new TypeToken<List<MyEntity>>() {}.getType());
    } catch (Exception e) {
      throw new BusinessException("Failed to read entity asset", e);
    }
  }

  // WRITE — сериализация в JSON, обновление ассета
  public void updateEntities(List<MyEntity> entities) {
    try {
      String json = gson.toJson(entities);
      orchestratorService.assets().update(MY_ENTITY_ASSET_NAME).text(json).execute();
    } catch (Exception e) {
      throw new BusinessException("Failed to update entity asset", e);
    }
  }
}
```

**Правила:**
- Всегда проверяйте `exists()` перед `get()` — ассет может не существовать при первом запуске.
- Возвращайте пустую коллекцию (не null), если ассет отсутствует или пуст.
- Оборачивайте все вызовы Orchestrator в try/catch → `BusinessException`.
- Имена ассетов — приватные константы, не раскрывайте `OrchestratorService` в Steps, которым он не нужен.

### AppNotificationService — обёртка email-уведомлений

Создайте один `AppNotificationService` на процесс, маппящий каждое бизнес-событие на имя email-шаблона:

```java
@Slf4j
@AllArgsConstructor
public class AppNotificationService {
  private final EmailService emailService;

  public void notificationWorkStart(Map<String, Object> values, EmailRecipients recipients) {
    emailService.sendByTemplateName("work_start", values, recipients);
  }
  public void notificationNewTasks(Map<String, Object> values, EmailRecipients recipients) {
    emailService.sendByTemplateName("new_tasks", values, recipients);
  }
  // ... один метод на каждое бизнес-событие
}
```

**Правила:**
- Имена шаблонов должны совпадать с ключами в `*_email_templates.json`.
- `values` — `Map<String, Object>` с `${variable}` плейсхолдерами, используемыми в шаблоне.
- `EmailRecipients` берётся из `initParams.getEmailRecipients()`.
- Steps создают `new AppNotificationService(emailService)` inline — не нужна инъекция Guice для этого класса.

## Manual Task (MT) Migration

WF Manual Task (папка `mt/mt_XX` с `*.html` FreeMarker + `*.js`) мигрируется на **Shadow Core Engine** —
регламент `rpa-core/src/test/resources/manualtask/`. Для актуального примера MT-паттерна (sender/receiver
Java-шаги + `actions/*.js`) запустите **Freshest Reference Discovery** по MT-процессам `rpa-suite` (master-gate,
свежайший, валидация против `rpa-core`). **Не переносите** WF FreeMarker-шаблон как есть — он не совместим с
Sherpa (нет `<@hit>`, `<@answers>`, `<@editable>`).

### Архитектура: асинхронный round-trip через очередь

WF-поток был синхронным (Prepare → MT → Save в одном запуске). На Sherpa поток **асинхронный**:
шаг-робот создаёт задачу в очереди → пользователь заполняет JS-форму в браузере → Orchestrator-триггер
(Task Queue, **статус задачи `NEW` + final-тег**) запускает receiver-запуск, который читает результат из задачи.
Поэтому каждый WF MT становится **двумя** Sherpa Step-ами:

| WF | Sherpa |
|---|---|
| `Prepare*Step` (+ Supplier) — готовит данные, экспортирует в MT | **Sender** — готовит данные + создаёт задачу в очереди (`tasks().create()`) с `initialData`-пейлоадом + email со ссылкой на Action |
| `Save*Step` — читает ответ MT | **Receiver** — запускается триггером, читает `tasks().listFromQueue()`, парсит submit-результат, выполняет существующий merge, сохраняет в транзакцию |

> **Модель триггеров Sherpa (важно).** Orchestrator-триггер срабатывает **только когда статус задачи =
> `NEW`**, отслеживая теги (final-тег). `tasks().create()` не меняет статус — задача создаётся и остаётся в
> `NEW`. Поэтому:
> - **auto-trigger** — sender создаёт задачу **сразу с final-тегом** в `NEW` → триггер запускает receiver без человека;
> - **manual** — sender создаёт задачу с pending-тегом; контролёр в JS-форме через `ShadowCore.checkAndMarkLastTask`
>   **добавляет** final-тег (`/api/task/addTag`), статус **не меняя** (остаётся `NEW`) → триггер срабатывает.
>
> Никогда не переводите задачу в `In Progress` руками — триггер на `In Progress` **не сработает**.

### Два пути создания задачи: auto-trigger vs manual

| Путь | Когда | Тег при `create()` | `initialData` | Статус | Email |
|---|---|---|---|---|---|
| **Manual** (все MT) | есть данные для ручной проверки | `MT_0X_PENDING_TAG` | полный payload + `bearerToken` | NEW | `new_tasks` (+ `${actionUrl}`) |
| **Auto-trigger** (MT с skip-веткой, напр. MT_01/MT_02) | данных нет (skip) | `MT_0X_FINAL_TAG` сразу | `Map.of()` (пусто) | NEW | `no_new_tasks` |

Auto-trigger создаёт задачу одним `tasks().create()` сразу с final-тегом → триггер запускает receiver без
ручной проверки. Receiver в skip-ветке **обязательно финализирует** задачу (SUCCESS + PROCESSED_TAG) — иначе
триггер будет пере-срабатывать бесконечно (см. skip-and-finalize ниже). MT_03 (безусловная ручная корректировка)
не имеет skip-ветки — всегда manual.

### Канонический состав Sherpa MT (по регламенту `manualtask/`)

MT не описывается единым манифестом — «дескриптор» размазан по Designer-конфигурации Action и Java-шагу.
Обязательные части:

1. **Action** (Sherpa Designer, **вне репо**): initial-тег (pending) + кнопка завершения (Save + swap тегов:
   добавить final, убрать pending). UUID Action хранится в init params (`...ActionLink`).
2. **Canvas Action** — два обязательных блока:
   - **HTML/JS-блок** с `manualtask/snippet.html` (лоадер: host `#a1-custom-block`, скрытый `#initialData`,
     `<link>`/`<script>` на file-ID `style.css`/`core.js`/`mt.js`).
   - **Системный Text input** с Label = `initialData`, имя параметра = `initialData` (его `core.js` прячет).
3. **File-storage ассеты** (загружаются в платформу, подключаются по file-ID в snippet): `style.css`,
   `core.js` (общий движок, **не менять**) и **`mt.js`** — пер-task бизнес-логика (этот файл — единственный
   артефакт MT в репо, кладётся в `src/main/resources/actions/<name>.js`).
4. **Очередь** в Orchestrator (по имени-строке) + **триггер** (Task Queue, очередь, условие по final-тегу,
   `lastTask`, **статус задачи `NEW`**, запуск receiver-стадии). Триггер срабатывает только на `NEW` + тег.
5. **Asset `sherpa_api_credentials`** (Credentials; password = bearer-токен) — нужен форме для JS-вызовов
   `ShadowCore.uploadFile`/`checkAndMarkLastTask` (`/api/files/*`, `/api/task/*`).

Ключевые константы регламента: параметр задачи **всегда** `initialData` (захардкожено в `core.js`),
host `#a1-custom-block`, URL `https://sherpa-{test|prod}.a1.by/api/files/download/{fileId}`.

### `actions/<name>.js` — пер-task скрипт (по образцу `manualtask/template.js` из `rpa-core`; актуальный пример MT-формы — через Freshest Reference Discovery)

```js
ShadowCore.render({
  debug: true,
  css: `...локальные переопределения поверх общих style.css...`,
  html: `<div class="card">...UI формы (таблицы/поля/кнопки)...</div>`,
  onReady: function (shadow, initialData) {
    // shadow — корень Shadow DOM (используйте shadow вместо document)
    // initialData — JSON, переданный из Java при tasks().create()
    // ...рендер, валидация...
    submitBtn.addEventListener("click", async function () {
      // (опционально) для batch-MT: отметить последнюю задачу final-тегом
      await ShadowCore.checkAndMarkLastTask(token, "QUEUE_NAME", "pendingTag", "finalTag");
      var payload = { userInput: { ...результат формы... } };
      ShadowCore.submit(payload); // инжектит payload в скрытый initialData + кликает Save
    });
  }
});
```

**Правила `mt.js`:**
- Всё внутри `onReady` — **не глобальные** функции. Поэтому **не** используйте inline-обработчики
  (`onclick="fn()"`) — они не видят функций из `onReady`. Вешайте слушатели через
  `el.addEventListener(...)` (как в `template.js`).
- Запросы к элементам — через `shadow.getElementById/querySelector`, **не** `document` (кроме
  `document.createTextNode` и поиска системных блоков вне shadow).
- Autocomplete/динамику стройте **DOM-методами + `textContent`** (не `innerHTML` с бизнес-данными —
  XSS из данных ассета). Скрытые `<input type="hidden">` создавайте через `createElement` + `.value`.
- `ShadowCore.submit(payload)` перезаписывает `initialData` задачи строкой `JSON.stringify(payload)`.
  Поэтому receiver парсит именно `initialData` → DTO. Заворачивайте результат в `{ userInput: {...} }`
  (сверьте с актуальным MT-процессом через Freshest Reference Discovery) — соответствует contractу receiver.
- Загрузка файлов (если нужна) — `ShadowCore.uploadFile(file, token, "FOLDER_NAME")`; `mt.js` без
  загрузки файлов `uploadFile` не вызывает, но `bearerToken` всё равно передаётся (для
  `checkAndMarkLastTask`).
- Скрывайте пустые секции (`display="none"`), если соответствующий список в `initialData` пуст.

### Sender-Step (создание задачи) — канонический шаблон (актуальный пример — через Freshest Reference Discovery)

```java
Asset.Credentials creds = orchestratorService.assets()
    .getCredentials(ProcessDataKeys.SHERPA_API_CREDENTIALS_ASSET).execute();
Map<String, Object> payload = new LinkedHashMap<>();
payload.put("...данныеДляФормы...", ...);
payload.put("bearerToken", creds.password());
// --- Manual path: есть данные для ручной проверки ---
orchestratorService.tasks().create()
    .queue(ProcessDataKeys.MT_XX_QUEUE_NAME)
    .name(ProcessDataKeys.MT_XX_TASK_NAME)
    .tags(ProcessDataKeys.MT_XX_PENDING_TAG)              // pending → контролёр добавит final через JS
    .parameters(Map.of("initialData", payload, "transactionName", resolveTransactionName(),
        "processStage", STAGE_N))
    .execute();
// email со ссылкой на Action:
emailService.sendByTemplateName("new_tasks",
    Map.of("mtName", ProcessDataKeys.MT_XX_NAME, "actionUrl", initParams.getXxActionLink()),
    recipients);
```

```java
// --- Auto-trigger path: данных нет (skip-ветка) ---
// Задача создаётся СРАЗУ с final-тегом в NEW → триггер запускает receiver без человека.
// initialData пустой; receiver по workflow_status="no_*" пропускает разбор, но финализирует.
orchestratorService.tasks().create()
    .queue(ProcessDataKeys.MT_XX_QUEUE_NAME)
    .name(ProcessDataKeys.MT_XX_TASK_NAME)
    .tags(ProcessDataKeys.MT_XX_FINAL_TAG)                // final сразу, без pending/без человека
    .parameters(Map.of("initialData", Map.of(), "transactionName", resolveTransactionName(),
        "processStage", STAGE_N))
    .execute();
emailService.sendByTemplateName("no_new_tasks",
    Map.of("mtName", ProcessDataKeys.MT_XX_NAME), recipients);
```

`processStage` = номер receiver-стадии (MT_01→2, MT_02→3, MT_03→4; 1 = первичный запуск без задачи).
`transactionName` = имя файла транзакции без расширения, из `System.getProperty("transaction.path")`;
`ReceiveRobotTask` позже скачивает файл из Storage по нему. `STAGE_N` — константа/литерал этапа.

Создавайте manual-задачу **только** когда есть данные для ручной проверки; иначе — auto-trigger + «no new
tasks» email. Безусловные MT (напр. MT_03 «внести изменения») всегда manual, skip-ветки не имеют.

### Receiver-Step (чтение результата) — канонический шаблон (актуальный пример — через Freshest Reference Discovery)

```java
// --- findSubmittedTask: фильтр по name + FINAL_TAG + статус NEW (НЕ IN_PROGRESS) ---
List<Task> tasks = orchestratorService.tasks()
    .listFromQueue(ProcessDataKeys.MT_XX_QUEUE_NAME).execute();
Task task = tasks.stream()
    .filter(t -> ProcessDataKeys.MT_XX_TASK_NAME.equals(t.getName()))   // отсечь decoy с чужим именем
    .filter(t -> t.getTagList().contains(ProcessDataKeys.MT_XX_FINAL_TAG))
    .filter(t -> t.getStatus() == TaskStatus.NEW)                       // триггер срабатывает на NEW
    .findFirst()
    .orElseThrow(() -> new IllegalStateException(
        "No MT task with final tag and status NEW in queue"));
// initialData после submit — строка (Map до submit). Покрыть оба варианта:
Object initial = task.getParameters().getParametersMap().get("initialData");
ProcessNewResult result;                                              // {MtName}Result — без префикса Mt
if (initial instanceof String s)      result = GSON.fromJson(s, ProcessNewResult.class);
else if (initial instanceof Map<?,?> m) result = GSON.fromJson(GSON.toJson(m), ProcessNewResult.class);
else { /* fallback: rawParameters → text.initialData */ }
// --- ветвление по workflow_status (skip-ветка пропускает разбор, но финализирует) ---
String workflowStatus = processTransaction.getWorkflowStatus().orElse(null);
if (ProcessDataKeys.STATUS_XX_EXIST.equals(workflowStatus)) {
  List<Account> processed = result.getUserInput().getProcessedAccounts();
  // ...существующий merge (checklist/comments), сохранение в транзакцию, email "task_processed"...
} else {
  log.info("Skipping MT processing (workflow_status='{}')", workflowStatus);
}
// --- ФИНАЛИЗАЦИЯ в ЛЮБОЙ ветке — снимает задачу с триггера (skip-and-finalize) ---
markTaskSuccess(task.getGuid());
markTaskProcessed(task.getGuid());
```

```java
// Два отдельных update(): tags() полностью ЗАМЕНЯЕТ список тегов задачи;
// сервер игнорирует пустое значение тегов, поэтому PROCESSED_TAG — непустой,
// чтобы очистить pending/reviewed. Поэтому финализация — именно два вызова.
private void markTaskSuccess(String taskGuid) {
  orchestratorService.tasks().update(taskGuid).status(TaskStatus.SUCCESS).execute();
}
private void markTaskProcessed(String taskGuid) {
  orchestratorService.tasks().update(taskGuid)
      .tags(ProcessDataKeys.MT_XX_PROCESSED_TAG).execute();
}
```

**skip-and-finalize инвариант:** даже при `workflow_status="no_*"` (auto-trigger skip-ветка) разбор
`processedAccounts` пропускается, но `markTaskSuccess` + `markTaskProcessed` выполняются **всегда** — иначе
задача останется в `NEW` с final-тегом и триггер пере-сработает бесконечно. Безусловные MT (без skip-ветки)
разбирают результат безусловно, но финализируют так же.

DTO результата (`model/{MtName}Result.java`, напр. `ProcessNewResult` — без префикса `Mt`) —
вложенный `UserInput` с `@SerializedName`-полями, совпадающими с ключами payload из `mt.js`
(и альтернативными именами сущности):

```java
@Data public class ProcessNewResult {
  private UserInput userInput;
  @Data public static class UserInput {
    @SerializedName("processedAccounts") private List<Account> processedAccounts;
  }
}
```

`OrchestratorService` инжектируется в receiver (конструктор), даже если до миграции он не был нужен.
Имена очереди/тегов/задачи — **константы** в `ProcessDataKeys` (не inline-строки), например
`MT_01_QUEUE_NAME = "ICS-XXXX ..."`.

### Константы `ProcessDataKeys` для MT + `processStage` + `transactionName`

На каждый MT — **6 констант** (канон; актуальный пример — через Freshest Reference Discovery):

```java
public static final String MT_01_QUEUE_NAME = "ICS-XXXX Название процесса";  // общая очередь
public static final String MT_01_NAME       = "Проверка новых ...";
public static final String MT_01_TASK_NAME  = "processNew";      // process{New|Changed|All}
public static final String MT_01_PENDING_TAG  = "pending";
public static final String MT_01_FINAL_TAG    = "reviewed";
public static final String MT_01_PROCESSED_TAG = "processed";
// MT_02/MT_03: QUEUE_NAME = MT_01_QUEUE_NAME (алиас — одна физическая очередь),
//   свои TASK_NAME (processChanged/processAll) и теги с суффиксами Changed/All:
//   pendingChanged/reviewedChanged/processedChanged, pendingAll/reviewedAll/processedAll.
public static final String SHERPA_API_CREDENTIALS_ASSET = "sherpa_api_credentials";
public static final String WORKFLOW_STATUS = "workflow_status";
public static final String STATUS_XX_EXIST = "..._exist";   // STATUS_NEW_ACCOUNTS_EXIST и т.п.
public static final String STATUS_NO_XX    = "no_...";      // STATUS_NO_NEW_ACCOUNTS и т.п.
```

- **Общая очередь + раздельные теги.** MT_02/MT_03 алиасят `MT_01_QUEUE_NAME` — одна физическая очередь,
  дифференциация по `taskName` + тегам. Суффиксы `Changed`/`All` на тегах MT_02+ нужны, чтобы
  `checkAndMarkLastTask` и Orchestrator-триггеры разных MT не конфликтовали в общей очереди.
- **`processStage`** (в `parameters()` задачи) = номер receiver-стадии: MT_01→2, MT_02→3, MT_03→4
  (1 = первичный запуск без задачи). `Switch/Case` в `.process` маршрутизирует по `$Parameters.processStage`.
- **`transactionName`** = имя файла транзакции без расширения, из `System.getProperty("transaction.path")`;
  `ReceiveRobotTask` позже скачивает файл транзакции из Storage по этому имени.

### Init params + email-шаблон

- `InitParameters`: поле `<mtName>ActionLink` (String) — UUID-ссылка на Action.
- `init_params/{test,prod}/*.json`: `"mtNameActionLink": "https://sherpa-{test|prod}.a1.by/main/my-actions/<UUID>"`
  (placeholder `00000000-...` до создания Action).
- Email-шаблон `new_tasks` (в `*_email_templates.json`): добавить плейсхолдер `${actionUrl}` и ссылку
  `<a href="${actionUrl}">открыть</a>` в `bodyTemplate`; sender кладёт `actionUrl` в `values`.

### Designer `.process` для MT

MT-диаграмма — **не** плоский Start→Steps→End. Структура канонической MT-диаграммы (актуальный пример — через Freshest Reference Discovery):

```
Start → Prepare*Step (sender, по одному на MT) → ReceiveRobotTask → Switch/Case → Save*Step (receiver, по одному на MT) → End
```

- **`ReceiveRobotTask`** (блок): свойство `QueueGuid` = `MT_01_QUEUE_NAME`; встроенный PowerShell
  `Get-TaskFromQueue` берёт задачу из очереди (сначала `Created`/`NEW`, fallback `InProgress`), выставляет
  `$Parameters` (карта параметров задачи — `initialData`, `transactionName`, `processStage`).
- **`Switch/Case`** (блок): `Statement = $Parameters.processStage`; `Condition2=2`→Save*Stage2 (MT_01),
  `Condition3=3`→Stage3 (MT_02), `Condition4=4`→Stage4 (MT_03); `Default` → первичный запуск (stage 1, без задачи).
- **Триггер** настраивается в admin-UI Orchestrator (вне репо): `{ queue: MT_01_QUEUE_NAME, tag: finalTag,
  status: NEW }` → запуск диаграммы с `ReceiveRobotTask`. Сам триггер **не в файле `.process`**.
- **`SaveTransaction=True` только на первом sender (Prepare) шаге.** Каждый `SaveTransaction=True` шаг
  вызывает `StorageCreateFile` под одним именем `transaction_<JobGuid>`; несколько таких шагов в одном запуске
  создают дубликаты в Storage и ломают `StorageReadFile` (`"Found more than 1 record"`). На всех остальных
  шагах — `False`.

> Сгенерированный скриптом `wf-migrate.ps1` MT-каркас диаграммы упрощён (без `Try/Catch`/`HandleError`/
> `Stage`-обёрток эталона) — обёртки и обработку ошибок добавьте в Designer вручную.

### Out-of-repo (Orchestrator/Designer — выполняет пользователь)

1. Создать Action: initial-тег (pending) + кнопка завершения (Save + swap на final-тег).
2. На canvas: HTML/JS-блок с `snippet.html` (подставить file-ID `style.css`/`core.js`/`mt.js`) +
   системный Text input `initialData`.
3. Загрузить в файловое хранилище `style.css`, `core.js` (из `rpa-core/src/test/resources/manualtask/`)
   и `actions/<name>.js` (из репо); подставить ID в snippet.
4. Создать очередь + триггер (Task Queue, очередь, условие по final-тегу, `lastTask`, **статус `NEW`**,
   запуск receiver-стадии). Триггер срабатывает только на `NEW` + final-тег.
5. Создать asset `sherpa_api_credentials` (Credentials; password = bearer-токен).
6. Подставить реальный UUID Action в `<mtName>ActionLink` init params (test/prod).

### Регламент и контракты (пути)

Канон — `rpa-core`. Конкретные актуальные примеры MT-реализаций (ShadowCore-формы, sender/receiver шаги,
триггерная модель, `processStage`, `.process`) получайте через **Freshest Reference Discovery** по MT-процессам
`rpa-suite` (master-gate, свежайший, валидация против `rpa-core`) — не опирайтесь на захардкоженные имена
процессов.

- Регламент: `rpa-core/src/test/resources/manualtask/` — `README.md`, `snippet.html`, `core.js`,
  `style.css`, `template.js`, `file_upload.js`, `batch_processing.js`.
- Канонические артефакты MT-процесса (ищите их в свежайшем merged-to-master процессе как подтверждение
  актуальной конвенции): `src/main/resources/actions/<name>.js` (ShadowCore-форма); sender-шаг
  (`tasks().create()`), receiver-шаг (`tasks().listFromQueue()` + фильтр NEW + финализация); DTO результата;
  `InitParameters` (`...ActionLink` поля); `initparams/{test,prod}/*_init_params.json`.
- Каноническая MT-архитектура (триггерная модель, auto-trigger/manual, финализация, `processStage`,
  `.process`): пары `Prepare*Step`/`Save*Step`; `transaction/ProcessDataKeys.java` (MT_01/02/03 константы);
  `src/main/resources/actions/*.js` (`ShadowCore.checkAndMarkLastTask`); `Главная.process`
  (`ReceiveRobotTask` — блок с `QueueGuid`, `Switch/Case` — `$Parameters.processStage`).
- Java-контракты: `rpa-core/.../orchestrator/model/Task.java` (`getParameters().getParametersMap()`,
  `getTagList()`, `getRawParameters()`), `OrchestratorService` (`tasks().create()/listFromQueue()`),
  `rpa-core/.../manualtask/core.js` (`checkAndMarkLastTask`: добавляет final-тег через `/api/task/addTag`,
  статус не меняет).

## Email Template Requirements

Файл `*_email_templates.json` должен содержать ключ для каждого имени шаблона, используемого в `AppNotificationService`.

### Перенос шаблонов дословно из источника WF — обязательно

Шаблоны переносятся в Sherpa `*_email_templates.json` **дословно** (тот же FreeMarker-текст). Не переписывайте
их «проще» и не убирайте плейсхолдеры — email-выход процесса должен остаться идентичным WF.

- **Шаблоны, унаследованные от WF `SystemNotificationService`** (`work_start`, `work_end`, `error` и т.п., из
  базы `a1lib/src/main/java/by/a1/lib/email/resources/email_templates.csv`) — ключи в Sherpa остаются те же
  (`work_start`/`work_end`, именно их вызывает `AppNotificationService.sendByTemplateName`). Сохранить:
  - фразу **«на отчетную дату.»** в теле `work_start`;
  - `${controlStatus!}` (default-empty) и блок `<#if controlResultsLink??><br><a href='${controlResultsLink}'>Результаты исполнения процесса</a></#if>` в теле `work_end`;
  - fallback `<#if processName??>${processName}<#else>${bpName}</#if>` (не заменять на голый `${processName}`);
  - плейсхолдер `${uuid}` (с guard `<#if uuid??>…</#if>`).
  Платформенный базовый шаблон `rpa-core/src/main/resources/email_templates.json` (`process_started`/`process_completed`)
  использует тот же синтаксис — значит Sherpa его поддерживает; `${controlStatus!}` и `<#if controlResultsLink??>`
  безопасны при отсутствии переменных (рендерят пусто/пропуск).
- **Кастомные per-process шаблоны** (напр. `manual_processing_required_notification`) — из WF per-process datastore
  `src/test/resources/datastores/*_email_templates.csv` (одна строка на шаблон, колонки `template,subject,body`),
  с сохранением bpName-fallback и всех плейсхолдеров.
- **MT-шаблоны** (`new_tasks`, `no_new_tasks`, `task_processed`) — для процессов с ручными задачами; см. раздел
  «Manual Task (MT) Migration» и пример ниже.

Canonical-тексты `work_start`/`work_end` (из WF base):

```json
{
  "work_start": {
    "subjectTemplate": "<#if processName??>${processName}<#else>${bpName}</#if><#if bpNumber?? && bpDescription??> ${bpNumber}_${bpDescription}</#if>: ботопроцесс запущен ${currentDate}",
    "bodyTemplate": "<style type=\"text/css\">body{font-family: Verdana, Arial, Helvetica, sans-serif}</style><#if processName??>${processName}<#else>${bpName}</#if><#if controlName??> ${controlName}</#if>: ботопроцесс <#if bpNumber?? && bpDescription??>${bpNumber}_${bpDescription} </#if>начат на отчетную дату. <#if uuid??><br><p style=\"color:rgba(0,0,0,0.5);\">uuid: ${uuid} </#if>"
  },
  "work_end": {
    "subjectTemplate": "<#if processName??>${processName}<#else>${bpName}</#if><#if bpNumber?? && bpDescription??> ${bpNumber}_${bpDescription}</#if>: ботопроцесс завершен ${currentDate}",
    "bodyTemplate": "<style type=\"text/css\">body{font-family: Verdana, Arial, Helvetica, sans-serif}</style><#if processName??>${processName}<#else>${bpName}</#if><#if controlName??> ${controlName}</#if>: ботопроцесс <#if bpNumber?? && bpDescription??>${bpNumber}_${bpDescription} </#if>завершен. ${controlStatus!}<#if controlResultsLink??><br><a href='${controlResultsLink}'>Результаты исполнения процесса</a></#if><br>Удачного дня! <#if uuid??><br><p style=\"color:rgba(0,0,0,0.5);\">uuid: ${uuid} </#if>"
  }
}
```

Пример MT-шаблонов (для процесса с ручными задачами; `${actionUrl}` — ссылка на Action, см. раздел MT):

```json
{
  "new_tasks": {
    "subjectTemplate": "<#if processName??>${processName}<#else>${bpName}</#if><#if bpNumber?? && bpDescription??> ${bpNumber}_${bpDescription}</#if>: ботопроцесс завершен ${currentDate}",
    "bodyTemplate": "<p>Новая задача в процессе ${processName}</p><p>Название задачи: ${mtName}</p><p>Дата: ${currentDate}</p><p><a href=\"${actionUrl}\">открыть</a></p>"
  },
  "no_new_tasks": { "subjectTemplate": "...", "bodyTemplate": "..." },
  "task_processed": { "subjectTemplate": "...", "bodyTemplate": "..." }
}
```

## Semantic Equivalence Gate (mandatory, blocking)

Before declaring any migration complete, perform a **semantic-equivalence review against the original WF source**. This is a hard release gate, not an optional code-quality review.

1. Read every migrated WF source file and its Sherpa counterpart in full.
2. Compare the source and target behavior as a whole, including inputs, outputs, control flow, transformations, side effects, error handling, and ordering.
3. Verify that the target is an equivalent transfer of the source. Any unexplained difference or “equivalent enough” substitution blocks the migration.
4. Test the meaningful branches and boundary conditions present in the source, not only the current happy path.
5. Record every platform-forced deviation separately with its reason, target behavior, and verification evidence. Any deviation not forced by the platform is prohibited.
6. Do not approve, publish, or report the process as migrated while this gate has an open discrepancy. Stop and ask the user when source behavior is ambiguous.

**Regression prevention rule:** do not substitute, reinterpret, simplify, reorder, or otherwise alter source behavior for convenience. A migration that changes behavior is functionally incorrect even if it compiles and passes one run.

## Validation Checklist

После завершения миграции проверьте:

- [ ] **Semantic Equivalence Gate пройден:** каждый мигрированный WF-компонент сопоставлен с исходником; поведение, порядок, условия, преобразования, side effects и обработка ошибок сохранены; все отклонения документированы как platform-forced; необъяснимых изменений нет
- [ ] **Процесс независим:** `build.gradle` зависит только от `:rpa-core` (+ сторонние библиотеки); нет
      импортов пакетов других процессов; **существующие процессы не модифицировались** во время миграции
- [ ] **Freshest Reference Discovery:** для платформенных вопросов вне канона применена процедура —
      master-gate, свежайший по коммиту на default-ветке, валидация против `rpa-core`; извлечён только
      принцип, без копирования имён/структуры и без кросс-процессных зависимостей
- [ ] Количество WF XML configs + Suppliers == количество Sherpa Step классов
- [ ] Все поля `AppInitParams` присутствуют в `InitParameters`
- [ ] Все константы `AppDoc.Column` / `AppTransaction.Column` присутствуют в `ProcessDataKeys`
- [ ] `ProcessTransaction` имеет и getter, и setter для всех data keys
- [ ] `build.gradle` содержит все обнаруженные зависимости
- [ ] Прямые зависимости в `build.gradle` соответствуют карте Phase 3 и ограничениям `rpa-core`; ни одна библиотека не переведена на major version 2 без явного решения пользователя
- [ ] PowerShell-скрипты скопированы в `resources/scripts/`
- [ ] `README.md` сгенерирован через скилл **write-readme** (шаги, init_params, email-шаблоны, сервисные переменные, MT-секция — из кода)
- [ ] README включает InfrastructureStep (или init Step) как шаг 1, если процесс имеет Supplier
- [ ] README перечисляет все email-шаблоны, включая `work_start`
- [ ] README документирует оба формата дат для InitParams (ISO и legacy)
- [ ] Нет `Set.of()` как mutable set — всегда `new HashSet<>(...)`
- [ ] Нет конкатенации строк для workflow status — используются константы `ProcessDataKeys.STATUS_*`
- [ ] Нет inline-строк для имён MT — используются `Constants.MT_*_NAME`
- [ ] `*_email_templates.json` имеет ключ для каждого имени шаблона, используемого в `AppNotificationService`
- [ ] `work_start`/`work_end` (и любые шаблоны, унаследованные от WF `SystemNotificationService`) перенесены **дословно** из WF base `a1lib/.../email_templates.csv` — с сохранением «на отчетную дату», `${controlStatus!}`, блока `controlResultsLink`, fallback `<#if processName??>${processName}<#else>${bpName}</#if>` и `${uuid}` (без упрощений); кастомные шаблоны — из per-process datastore CSV с bpName-fallback
- [ ] Utility расчёта периода обрабатывает оба формата дат с fallback
- [ ] Unit-тесты написаны одним батчем **только для нетривиальной логики** (datastore CSV→JSON фикстуры,
      расчётные утилиты/парсеры, нетривиальный merge) — простые шаги-мапперы без тестов (см. «Migration
      Priorities»); реализация написана раньше тестов, не TDD
- [ ] OrchestratorService mock-chain протестирован **только если** Step с `ProcessStateService` содержит
      нетривиальную логику (не тривиальный маппинг)
- [ ] Datastore CSV-фикстуры (`src/test/resources/datastores/*.csv`) конвертированы в JSON-фикстуры (`src/test/resources/<feature>/<env>/*.json`) для unit-тестов Steps
- [ ] Название Java-проекта: lowercase, kebab-case, номер контроля без дефиса (`icsNNNNN`)
- [ ] `.sherpa`/`.process` названы по документации БП; несколько `.process` — через пробел с идентификатором; папки аналогично директориям Java-проекта
- [ ] **Non-MT `Главная.process`**: нет блока получения задачи из очереди (`OrchGetDefaultTask`/`ReceiveRobotTask`); диаграмма имеет вид `Старт → Try/Catch → Steps → Конец` + `Try/Catch → HandleError → Прервать`; `Try/Catch --Next→` привязан к первому бизнес-Step (или к `Конец`, если шагов нет); `SaveTransaction=True` только на первом Step; `HandleError.InitParamsAssetName`/`EmailTemplatesAssetName` ссылаются на ассеты процесса; **у всех Java-Step блоков `Args=""` (не `$TaskGuid`)** — иначе `$Args` = `$null` и обёртка блока падает на `$Args.Replace(...)` с `[UNHANDLED ERROR] You cannot call a method on a null-valued expression`
- [ ] **`Args="$TaskGuid"` отсутствует во всех `.process` без приёмника задач** (включая подпроцессные диаграммы, скопированные из скелета): `grep -c 'Value="\$TaskGuid"' *.process` → 0 совпадений в каждой диаграмме без `TaskGuid =`; генератор чинит это автоматически (`Repair-JavaStepArgs`, строка `Repaired` в отчёте), но ручные правки скелета нужно проверять вручную; после правки `.process` **перепубликовать `.robot`** — в нём лежат устаревшие копии диаграмм
- [ ] Storage-папка явно сопоставлена с исходным S3 bucket/key prefix и документирована отдельно от имени файла
- [ ] Storage `name`/`exists`/`update`/`download` используют одно плоское имя без `/` и `\\`; SharePoint/local staging hierarchy не передаётся в Storage
- [ ] Для ICS-60112 бизнес-файлы загружаются в Storage-папку `ICS-60112` без вложенной иерархии; transaction folder `transactions` используется только для транзакционных файлов
- [ ] Имена ассетов Orchestrator: lowercase, `_`-разделитель, номер контроля без дефиса (`icsNNNNN_init_params`)
- [ ] Название триггера: `<процесс> <частота/источник>` (напр. `ICS-NNNNN Daily`)
- [ ] Версия процесса: старт 0.1.0, первая релизная 1.0.0

**Manual Task (MT) — дополнительно (см. раздел «Manual Task (MT) Migration»):**
- [ ] WF FreeMarker-шаблон `mt/mt_XX/*.html` **не** перенесён как есть — мигрирован в ShadowCore `src/main/resources/actions/<name>.js`
- [ ] Каждый WF MT имеет sender-Step (создаёт `tasks().create()`) и receiver-Step (`tasks().listFromQueue()` по final-тегу)
- [ ] **Триггер Orchestrator настроен на final-тег при статусе `NEW`** (НЕ `In Progress`) — триггеры срабатывают только на `NEW` + тег
- [ ] **Auto-trigger skip-ветка** (для MT с возможностью «нет данных»): задача создаётся с `MT_0X_FINAL_TAG` + пустым `initialData` в `NEW`; receiver в skip-ветке **skip-and-finalize** (SUCCESS + PROCESSED_TAG) — иначе триггер пере-срабатывает бесконечно
- [ ] **Manual-ветка**: задача создаётся с `MT_0X_PENDING_TAG` + полным `initialData` (+ `bearerToken`); `mt.js` добавляет final-тег через `ShadowCore.checkAndMarkLastTask` (статус **не меняется**, остаётся `NEW`)
- [ ] `findSubmittedTask` фильтрует по `name + MT_0X_FINAL_TAG + status==TaskStatus.NEW` (не `IN_PROGRESS`); decoy-задачи с чужим именем или не-NEW — отбрасываются
- [ ] **Финализация — два отдельных `update()`**: `update(guid).status(SUCCESS)` + `update(guid).tags(MT_0X_PROCESSED_TAG)` (tags() полностью заменяет список; сервер игнорирует пустые теги → PROCESSED_TAG непустой, чтобы очистить pending/reviewed) — выполняется в **каждой** ветке receiver
- [ ] `processStage` передаётся в `parameters()` задачи (MT_01→2, MT_02→3, MT_03→4); `Switch/Case` в `.process` маршрутизирует по `$Parameters.processStage`
- [ ] 6 констант `MT_0X_*` на каждый MT (`QUEUE_NAME`/`NAME`/`TASK_NAME`/`PENDING_TAG`/`FINAL_TAG`/`PROCESSED_TAG`); общая очередь (MT_02+ алиасят MT_01), суффиксы тегов `Changed`/`All` для MT_02+; плюс `SHERPA_API_CREDENTIALS_ASSET`, `WORKFLOW_STATUS`, `STATUS_*_EXIST`/`STATUS_NO_*`
- [ ] **`.process`**: блоки `ReceiveRobotTask` (`QueueGuid`=`MT_01_QUEUE_NAME`) + `Switch/Case` (`Statement=$Parameters.processStage`, `Condition2/3/4`); `SaveTransaction=True` только на первом sender (Prepare) шаге
- [ ] `mt.js`: слушатели через `addEventListener` (не inline-обработчики), запросы через `shadow.*`, динамический контент через DOM/`textContent` (не `innerHTML` с бизнес-данными)
- [ ] `mt.js` submit-результат завёрнут в `{ userInput: {...} }` и отправлен через `ShadowCore.submit`
- [ ] Receiver парсит `initialData` (и String, и Map варианты) → DTO результата (`@SerializedName` совпадают с payload)
- [ ] Имена очереди/тегов/задачи — константы в `ProcessDataKeys` (`MT_XX_QUEUE_NAME/TASK_NAME/PENDING_TAG/FINAL_TAG`)
- [ ] `InitParameters` имеет `<mtName>ActionLink`; `init_params` (test+prod) содержат UUID-ссылку
- [ ] Email-шаблон `new_tasks` содержит `${actionUrl}`; sender кладёт `actionUrl` в `values`; для skip-ветки — `no_new_tasks`
- [ ] Asset `sherpa_api_credentials` задокументирован в README; `bearerToken` передаётся в `initialData`
- [ ] Очередь, теги, Action-ссылка, триггер Orchestrator (NEW+тег) и `actions/<name>.js` входят в MT-секцию вывода `write-readme`
- [ ] `OrchestratorService` mock-chain протестирован для sender (`create()`) и receiver (`listFromQueue()` + фильтр NEW + `update().status(SUCCESS)` + `update().tags(PROCESSED_TAG)`) — **только если** их логика нетривиальна (см. «Migration Priorities»)

## README.md

`README.md` is produced by the **`write-readme`** skill — run it against the
process directory after the Step classes and `StepName` wiring in `.process` are
done (it overwrites the placeholder `README.md` laid down by
`gradle generateProcess`). `write-readme` deterministically extracts from the
code: Description / Steps / Configuration (`init_params`, email templates) /
Service Variables, plus the **MT section** for MT processes (forms
`actions/*.js`, `*ActionLink` fields, Prepare/Save step pairs, `MT_<NN>_*`
constants, Orchestrator-setup). The MT section comes out of `write-readme` — do
**not** hand-write it. Do **not** reference another process by name in the new
README.

## Finding a concrete example (Freshest Reference Discovery)

There is **no fixed table of reference projects**. Processes age, and the platform conventions (`.sherpa`
schema, `.process` block version, Orchestrator API, MT regulation) evolve, so a hardcoded "use process X
for type Y" map goes stale the moment a newer process is merged. Instead, when you need a concrete example
of how a technology is implemented today, run **Freshest Reference Discovery** (see «Process Independence &
Reuse Strategy»):

1. Enumerate sibling processes in `rpa-suite` (exclude `rpa-core` and the process being migrated).
2. Apply the **master gate** — only processes present on the default branch (`master`).
3. Rank by last commit date on `master`, newest first.
4. Match the target technology by the Phase 2 detection heuristics (`build.gradle` deps + service classes +
   resources; the keyword→technology map, not process names):

| Target technology | Detection signals (Phase 2) |
|---|---|
| Email + AD + JSD + PowerShell | `email`/`smtp` + `ad`/`ldap` + `jira`/`jsd` + `.ps1`/`jPowerShell` |
| SAP + 1C + Email + JSD | `rpa-sapgui` + `jacob.jar` + email + jira |
| DB + AD + QRadar + HTTP | `sql`/`jdbc` + `ad` + http client + QRadar client |
| Oracle + Email | `ojdbc` + email |
| Excel + Jira + PowerShell | `poiji`/`poi` + `jira` + `.ps1` |

5. **Validate** the found pattern against `rpa-core` — `rpa-core` wins on conflict.
6. Extract the **principle only**; never copy names/structure, never introduce a cross-process dependency.

## Commit Message Format

```
{process_name} {issue_number} Миграция из Workfusion

[+] структура проекта (gradle generateProcess)
[+] Step классы: {Step1}, {Step2}, {Step3}
[+] ProcessTransaction, ProcessDataKeys
[+] InitParameters
[+] зависимости: {detected dependencies}
[~] требуется доработка логики в execute()
```

## Code Generation via PowerShell

The bundled analyzer script can generate Java source files directly from the WF analysis:

```powershell
.\scripts\wf-migrate.ps1 `
  -WfProcessPath "C:\path\to\wf\process" `
  -SherpaProjectName "my-process" `
  -DesignerProjectName "Мой процесс Описание" `
  -GenerateCode `
  -OutputPath "C:\path\to\output"
```

Generated files:
- `model/InitParameters.java` — all fields from WF `AppInitParams` with correct types
- `transaction/ProcessDataKeys.java` — constants from WF `AppDoc` / `AppTransaction`
- `transaction/ProcessTransaction.java` — `get`/`set` methods for all data keys
- `steps/{Processor}Step.java` — one Step class per WF Processor (with `TODO` for business logic)
- `build.gradle` — all detected dependencies
- `resources/scripts/*.ps1` — copied PowerShell scripts from WF

**Note:** Generated Step classes contain `TODO` placeholders for business logic. The developer must adapt the logic from WF Processor `execute()` methods.

## Bundled Resources

- `scripts/wf-migrate.ps1` — PowerShell analyzer and code generator that scans a WF process directory and optionally produces Java source files, a structured JSON report, and `build.gradle`.

## Important Notes

- Migration is optimized for **speed and verbatim accuracy of the transfer** — testing and code review follow
  the «Migration Priorities» section (minimal batch tests after code, no CR loop).
- **Never remove `EmailRecipients`** from `InitParameters.java` — it is required by rpa-core.
- **Never absorb WF Supplier logic into another Step** — each Supplier becomes its own Step.
- **Always use `gradle generateProcess`** for project skeleton creation — do not create the structure manually.
- **Always use `ProcessDataKeys` constants** instead of string literals or string concatenation for transaction keys and status values.
- **Always use `new HashSet<>(...)`** instead of `Set.of()` when the set needs to be mutable.
- Java 21+, Gradle 8.5+, Sherpa RPA platform required.
- Retry mechanism: `-Dstep.maxRetries=<n>` (default 0), `-Dstep.retryDelayMs=<n>` (default 1000ms).
- Guice DI: `OrchestratorService` (credentials, assets), `EmailService` (email), `TransactionRepository` (singleton).
