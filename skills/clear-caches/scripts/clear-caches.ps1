<#
.SYNOPSIS
    Сканирует и очищает кеши на рабочей машине Windows.

.DESCRIPTION
    Показывает категории кешей с реальными размерами, уровнем риска и требованием
    прав администратора, затем удаляет только то, что подтверждено.

    По умолчанию — интерактивно: вопрос по каждой категории, дефолт «нет».
    Флаг -Force отключает вопросы (использовать ТОЛЬКО после явного согласия
    человека в чате).

    Категории, требующие прав администратора, при отсутствии прав пропускаются
    с явным сообщением — молчаливого «ничего не удалилось» не бывает.

.PARAMETER Categories
    Имена категорий для обработки. Пусто — все категории по порядку.

.PARAMETER Force
    Не задавать вопросов подтверждения. Все выбранные категории будут очищены.

.EXAMPLE
    .\clear-caches.ps1
    Показать все категории и спросить по каждой.

.EXAMPLE
    .\clear-caches.ps1 -Categories temp,thumbnails
    Ограничить набор категорий, подтверждение по каждой.

.EXAMPLE
    .\clear-caches.ps1 -Categories npm -Force
    Очистить кеш npm без вопросов (человек уже подтвердил).

.NOTES
    Часть clear-caches skill. IntelliJ и ~\.claude\projects намеренно НЕ входят
    в область: первое требует закрытой IDE, второе содержит историю сессий.
#>
[CmdletBinding()]
param(
    [string[]]$Categories = @(),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$script:IsAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$script:UserProfile = [Environment]::GetFolderPath('UserProfile')
$script:PromptUnavailable = $false

function New-CacheCategory {
    <#
    .SYNOPSIS
        Описывает одну категорию кеша — единый источник правды по путям и рискам.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][ValidateSet('low', 'medium', 'high')][string]$Risk,
        [ValidateSet('Contents', 'Command', 'Launch', 'None')][string]$Kind = 'Contents',
        [string]$Path,
        [string]$Filter = '*',
        [string]$Command,
        [string[]]$CommandArgs = @(),
        [switch]$RequiresAdmin,
        [string]$RiskNote
    )

    [pscustomobject]@{
        Name          = $Name
        Description   = $Description
        Risk          = $Risk
        Kind          = $Kind
        Path          = $Path
        Filter        = $Filter
        Command       = $Command
        CommandArgs   = $CommandArgs
        RequiresAdmin = [bool]$RequiresAdmin
        RiskNote      = $RiskNote
    }
}

$cacheCategories = @(
    # --- Windows ---
    (New-CacheCategory -Name 'temp' -Description 'Временные файлы пользователя (%TEMP%)' `
        -Path $env:TEMP -Risk 'low' `
        -RiskNote 'Занятые файлы пропускаются — это норма.')
    (New-CacheCategory -Name 'windows-temp' -Description 'Системные временные файлы (C:\Windows\Temp)' `
        -Path 'C:\Windows\Temp' -Risk 'low' -RequiresAdmin)
    (New-CacheCategory -Name 'prefetch' -Description 'Кеш предзагрузки приложений (C:\Windows\Prefetch)' `
        -Path 'C:\Windows\Prefetch' -Risk 'low' -RequiresAdmin `
        -RiskNote 'Первый запуск программ после очистки будет медленнее.')
    (New-CacheCategory -Name 'thumbnails' -Description 'Кеш эскизов проводника' `
        -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer') `
        -Filter 'thumbcache_*.db' -Risk 'low' `
        -RiskNote 'Полный эффект — после перезапуска проводника.')
    (New-CacheCategory -Name 'inetcache' -Description 'Кеш Internet/WebCache пользователя' `
        -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\INetCache') -Risk 'low')
    (New-CacheCategory -Name 'store-cache' -Description 'Кеш Microsoft Store (wsreset.exe)' `
        -Kind 'Launch' -Command 'WSReset.exe' -Risk 'low' `
        -RiskNote 'Интерактивно: открывает окно Store, автоматически не выполняется.')
    (New-CacheCategory -Name 'disk-cleanup' -Description 'Утилита «Очистка диска» (cleanmgr)' `
        -Kind 'Launch' -Command 'cleanmgr.exe' -Risk 'low' `
        -RiskNote 'GUI. /sagerun: без сохранённого профиля /sageset ничего не делает.')

    # --- Dev-тулчейн ---
    (New-CacheCategory -Name 'npm' -Description 'Кеш загрузок npm (npm cache clean --force)' `
        -Kind 'Command' -Command 'npm' -CommandArgs @('cache', 'clean', '--force') -Risk 'low' `
        -RiskNote 'Очищает только _cacache. Каталог _npx не затрагивает — это отдельная категория npm-npx.')
    (New-CacheCategory -Name 'npm-npx' -Description 'Кеш npx (~\npm-cache\_npx)' `
        -Path (Join-Path $env:LOCALAPPDATA 'npm-cache\_npx') -Risk 'low' `
        -RiskNote 'Пакеты, скачанные npx. У npm нет команды для этого каталога — удаляется напрямую, перекачается при следующем запуске npx.')
    (New-CacheCategory -Name 'pip' -Description 'Кеш pip (pip cache purge)' `
        -Kind 'Command' -Command 'pip' -CommandArgs @('cache', 'purge') -Risk 'low')
    (New-CacheCategory -Name 'maven' -Description 'Локальный репозиторий Maven (~\.m2\repository)' `
        -Path (Join-Path $script:UserProfile '.m2\repository') -Risk 'high' `
        -RiskNote 'Содержит ВНУТРЕННИЕ артефакты A1 (a1lib, by.a1): при недоступности корпоративного Nexus НЕ восстановятся.')
    (New-CacheCategory -Name 'gradle' -Description 'Кеши Gradle (~\.gradle\caches)' `
        -Kind 'Contents' -Path (Join-Path $script:UserProfile '.gradle\caches') -Risk 'high' `
        -RiskNote 'Следующий билд перекачает зависимости. Сначала останавливается демон Gradle (gradle --stop).')

    # --- Claude Code (projects/ намеренно исключён) ---
    (New-CacheCategory -Name 'claude-shell-snapshots' -Description 'Claude Code: снапшоты shell' `
        -Path (Join-Path $script:UserProfile '.claude\shell-snapshots') -Risk 'low')
    (New-CacheCategory -Name 'claude-paste-cache' -Description 'Claude Code: кеш вставленного текста' `
        -Path (Join-Path $script:UserProfile '.claude\paste-cache') -Risk 'low')
    (New-CacheCategory -Name 'claude-file-history' -Description 'Claude Code: история правок файлов' `
        -Path (Join-Path $script:UserProfile '.claude\file-history') -Risk 'medium' `
        -RiskNote 'Теряется возможность откатить правки, сделанные агентом.')
)

function Get-PathSizeBytes {
    <#
    .SYNOPSIS
        Суммарный размер файлов в каталоге. $null — каталог недоступен или не существует.

    .DESCRIPTION
        При заданном Filter считает только те элементы, которые реально попадут под
        удаление, — иначе показанный размер завышал бы освобождаемое место.

        MissingAsZero меняет трактовку отсутствующего каталога на 0 байт. После
        очистки каталог может исчезнуть целиком (npm cache clean --force удаляет
        _cacache), а это значит, что освобождено всё: $null в разнице «до/после»
        обнулил бы отчёт. $null сохраняется для существующего, но недоступного
        каталога, чтобы не завышать освобождённое место.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = '*',
        [switch]$MissingAsZero
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($MissingAsZero) {
            return [int64]0
        }
        return $null
    }

    if ($Filter -eq '*') {
        $items = Get-ChildItem -LiteralPath $Path -Recurse -Force -File -ErrorAction SilentlyContinue
    } else {
        $items = Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $Filter } |
            ForEach-Object {
                if ($_.PSIsContainer) {
                    Get-ChildItem -LiteralPath $_.FullName -Recurse -Force -File -ErrorAction SilentlyContinue
                } else {
                    $_
                }
            }
    }

    $sum = ($items | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sum) {
        return [int64]0
    }
    return [int64]$sum
}

function Format-SizeText {
    param([Nullable[int64]]$Bytes)

    if ($null -eq $Bytes) {
        return 'н/д'
    }
    if ($Bytes -ge 1GB) { return ('{0:N2} ГБ' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} МБ' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} КБ' -f ($Bytes / 1KB)) }
    return ('{0} Б' -f $Bytes)
}

function Get-CategorySizeBytes {
    param(
        [Parameter(Mandatory)]$Category,
        [switch]$MissingAsZero
    )

    switch ($Category.Kind) {
        'Contents' {
            return (Get-PathSizeBytes -Path $Category.Path -Filter $Category.Filter -MissingAsZero:$MissingAsZero)
        }
        'Command' {
            # Кеш внешнего инструмента измеряется по фактическому пути хранилища.
            $knownPath = switch ($Category.Name) {
                # Только _cacache: ровно то, что очищает npm cache clean --force.
                # Весь каталог npm-cache включал бы _npx и завышал бы освобождаемое.
                'npm' { Join-Path $env:LOCALAPPDATA 'npm-cache\_cacache' }
                'pip' { Join-Path $env:LOCALAPPDATA 'pip\Cache' }
                default { $null }
            }
            if ($knownPath) { return (Get-PathSizeBytes -Path $knownPath -MissingAsZero:$MissingAsZero) }
            return $null
        }
        'Launch' { return $null }
        default { return $null }
    }
}

function Get-FreeSpaceBytes {
    <#
    .SYNOPSIS
        Свободное место на C: в байтах, либо $null.
    #>
    $drive = Get-PSDrive -Name C -ErrorAction SilentlyContinue
    if ($null -eq $drive) {
        return $null
    }
    return [int64]$drive.Free
}

function Get-LockHolderWarning {
    <#
    .SYNOPSIS
        Предупреждение, если кеш занят запущенным процессом.

    .DESCRIPTION
        Кеши Maven и Gradle держат IDE и демоны сборки. Без предупреждения чистка
        выглядит успешной, но проходит частично — занятые файлы молча пропускаются.
    #>
    param([Parameter(Mandatory)][string]$CategoryName)

    $pattern = switch ($CategoryName) {
        'maven' { '^(idea64|ideaIC|java)' }
        'gradle' { '^(idea64|ideaIC|java|gradle)' }
        default { $null }
    }
    if (-not $pattern) {
        return $null
    }

    $found = @(Get-Process -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -match $pattern } |
            Select-Object -ExpandProperty ProcessName -Unique)
    if ($found.Count -eq 0) {
        return $null
    }
    return ('кеш занят: {0} — закройте IDE и остановите демоны для полной очистки' -f ($found -join ', '))
}

function Remove-PathContents {
    <#
    .SYNOPSIS
        Удаляет содержимое каталога, оставляя сам каталог на месте.

    .DESCRIPTION
        Сам каталог не удаляется: %TEMP% и подобные пути должны существовать.
        Занятые файлы пропускаются и считаются — это ожидаемое поведение, а не сбой.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = '*'
    )

    $outcome = [pscustomobject]@{ Removed = 0; Skipped = 0; FreedBytes = [int64]0 }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $outcome
    }

    $before = Get-PathSizeBytes -Path $Path -Filter $Filter
    $children = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like $Filter })

    foreach ($child in $children) {
        try {
            Remove-Item -LiteralPath $child.FullName -Recurse -Force -ErrorAction Stop
            $outcome.Removed++
        } catch {
            $outcome.Skipped++
        }
    }

    $after = Get-PathSizeBytes -Path $Path -Filter $Filter -MissingAsZero
    if ($null -ne $before -and $null -ne $after) {
        $outcome.FreedBytes = [int64]($before - $after)
    }
    return $outcome
}

function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Запускает внешнюю команду, возвращает вывод и код возврата.

    .DESCRIPTION
        PowerShell 5.1 превращает первую строку stderr нативной команды в
        NativeCommandError, а при $ErrorActionPreference='Stop' — в исключение.
        npm и pip пишут в stderr обычные предупреждения, из-за чего успешная
        команда выглядела как сбой. На время вызова режим ослабляется, а успех
        определяется кодом возврата, а не наличием вывода в stderr.
    #>
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$CommandArgs = @()
    )

    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $Command @CommandArgs 2>&1 | Out-String).Trim()
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }

    return [pscustomobject]@{
        ExitCode  = $exitCode
        FirstLine = ($text -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    }
}

function Invoke-CategoryCleanup {
    <#
    .SYNOPSIS
        Выполняет очистку одной категории и возвращает результат.
    #>
    param([Parameter(Mandatory)]$Category)

    switch ($Category.Kind) {
        'Contents' {
            $before = Get-PathSizeBytes -Path $Category.Path
            $note = $null
            if ($Category.Name -eq 'gradle') {
                # Демон Gradle держит локи на ~\.gradle\caches — останавливаем до удаления.
                try {
                    $null = & gradle --stop 2>&1
                    $note = 'демон Gradle остановлен'
                } catch {
                    $note = 'gradle --stop недоступен, часть файлов может быть занята'
                }
            }
            $result = Remove-PathContents -Path $Category.Path -Filter $Category.Filter
            if ($note) {
                $result | Add-Member -NotePropertyName Note -NotePropertyValue $note
            }
            return $result
        }
        'Command' {
            $before = Get-CategorySizeBytes -Category $Category
            $run = Invoke-NativeCommand -Command $Category.Command -CommandArgs $Category.CommandArgs
            $after = Get-CategorySizeBytes -Category $Category -MissingAsZero
            $freed = [int64]0
            if ($null -ne $before -and $null -ne $after) { $freed = [int64]($before - $after) }
            if ($run.ExitCode -ne 0) {
                throw ('{0} завершился с кодом {1}: {2}' -f $Category.Command, $run.ExitCode, $run.FirstLine)
            }
            return [pscustomobject]@{
                Removed    = 0
                Skipped    = 0
                FreedBytes = $freed
                Note       = $run.FirstLine
            }
        }
        'Launch' {
            Write-Host ('    запуск: {0}' -f $Category.Command) -ForegroundColor Cyan
            Start-Process -FilePath $Category.Command | Out-Null
            return [pscustomobject]@{
                Removed   = 0
                Skipped   = 0
                FreedBytes = [int64]0
                Note      = 'интерактивный инструмент запущен'
            }
        }
        default {
            return [pscustomobject]@{ Removed = 0; Skipped = 0; FreedBytes = [int64]0 }
        }
    }
}

function Select-CacheCategories {
    param([string[]]$Requested)

    if ($Requested.Count -eq 0) {
        return $cacheCategories
    }

    $known = $cacheCategories.Name
    $unknown = @($Requested | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -gt 0) {
        throw ("Неизвестные категории: {0}`nДоступные: {1}" -f ($unknown -join ', '), ($known -join ', '))
    }
    return @($cacheCategories | Where-Object { $Requested -contains $_.Name })
}

function Confirm-CategoryAction {
    <#
    .SYNOPSIS
        Спрашивает подтверждение по категории. Дефолт — «нет».

    .DESCRIPTION
        В неинтерактивной сессии (агент, CI, перенаправленный ввод) Read-Host
        недоступен и бросает исключение. Это не ошибка, а безопасный случай:
        считаем ответ «нет» и выставляем флаг, чтобы один раз объяснить причину.
    #>
    param([Parameter(Mandatory)]$Category)

    if ($Force) {
        return $true
    }
    $lockWarning = Get-LockHolderWarning -CategoryName $Category.Name
    if ($lockWarning) {
        Write-Host ('  ВНИМАНИЕ ({0}): {1}' -f $Category.Name, $lockWarning) -ForegroundColor Yellow
    }
    try {
        $answer = Read-Host ("  Очистить '{0}'? [y/N]" -f $Category.Name)
    } catch {
        $script:PromptUnavailable = $true
        return $false
    }
    return ($answer -match '^(y|yes|д|да)$')
}

function Write-ScanTable {
    param([Parameter(Mandatory)][array]$Items)

    Write-Host ''
    Write-Host '  Категории кешей:' -ForegroundColor White
    Write-Host ('  {0,-24} {1,12}  {2,-8} {3}' -f 'ИМЯ', 'РАЗМЕР', 'РИСК', 'ОПИСАНИЕ') -ForegroundColor DarkGray
    Write-Host ('  ' + ('-' * 100)) -ForegroundColor DarkGray

    foreach ($item in $Items) {
        $size = Format-SizeText -Bytes (Get-CategorySizeBytes -Category $item)
        $risk = $item.Risk.ToUpper()
        $flags = ''
        if ($item.RequiresAdmin) { $flags += ' [нужен админ]' }
        Write-Host ('  {0,-24} {1,12}  {2,-8} {3}{4}' -f $item.Name, $size, $risk, $item.Description, $flags)
        if ($item.RiskNote) {
            Write-Host ('  {0,-24} {1,12}  {2,-8} {3}' -f '', '', '', $item.RiskNote) -ForegroundColor DarkGray
        }
        $lockWarning = Get-LockHolderWarning -CategoryName $item.Name
        if ($lockWarning) {
            Write-Host ('  {0,-24} {1,12}  {2,-8} {3}' -f '', '', '', $lockWarning) -ForegroundColor Yellow
        }
    }
    Write-Host ''
}

# --- Основной поток ---

Write-Host ''
Write-Host '  Очистка кешей' -ForegroundColor White
if (-not $script:IsAdmin) {
    Write-Host '  Права администратора отсутствуют: категории windows-temp и prefetch будут пропущены.' -ForegroundColor Yellow
    Write-Host '  Для них запустите скрипт из консоли с повышенными правами.' -ForegroundColor DarkGray
}

try {
    $selected = @(Select-CacheCategories -Requested $Categories)
} catch {
    Write-Host ('  ОШИБКА: {0}' -f $_.Exception.Message) -ForegroundColor Red
    exit 2
}

Write-ScanTable -Items $selected

if (-not $Force) {
    Write-Host '  По каждой категории будет задан вопрос. Дефолт — «нет».' -ForegroundColor DarkGray
    Write-Host ''
}

$freeBefore = Get-FreeSpaceBytes
$report = New-Object System.Collections.Generic.List[object]

foreach ($category in $selected) {
    if ($category.RequiresAdmin -and -not $script:IsAdmin) {
        Write-Host ('  ПРОПУСК {0}: требуются права администратора.' -f $category.Name) -ForegroundColor Yellow
        $report.Add([pscustomobject]@{ Name = $category.Name; Status = 'пропущено (нужен админ)'; Freed = [int64]0; Detail = '' })
        continue
    }

    if (-not (Confirm-CategoryAction -Category $category)) {
        Write-Host ('  Отказ: {0}' -f $category.Name) -ForegroundColor DarkGray
        $report.Add([pscustomobject]@{ Name = $category.Name; Status = 'отклонено'; Freed = [int64]0; Detail = '' })
        continue
    }

    try {
        $result = Invoke-CategoryCleanup -Category $category
        $detail = ''
        if ($result.PSObject.Properties.Name -contains 'Skipped' -and $result.Skipped -gt 0) {
            $detail = ('пропущено занятых: {0}' -f $result.Skipped)
        }
        if ($result.PSObject.Properties.Name -contains 'Note' -and $result.Note) {
            if ($detail) { $detail += '; ' }
            $detail += $result.Note
        }
        Write-Host ('  Готово {0}: освобождено {1}' -f $category.Name, (Format-SizeText -Bytes $result.FreedBytes)) -ForegroundColor Green
        $report.Add([pscustomobject]@{ Name = $category.Name; Status = 'очищено'; Freed = $result.FreedBytes; Detail = $detail })
    } catch {
        Write-Host ('  ОШИБКА {0}: {1}' -f $category.Name, $_.Exception.Message) -ForegroundColor Red
        $report.Add([pscustomobject]@{ Name = $category.Name; Status = 'ошибка'; Freed = [int64]0; Detail = $_.Exception.Message })
    }
}

if ($script:PromptUnavailable) {
    Write-Host ''
    Write-Host '  Неинтерактивная сессия: подтверждение недоступно, ничего не удалено.' -ForegroundColor Yellow
    Write-Host '  Запустите скрипт вручную в терминале, либо повторите с -Force' -ForegroundColor DarkGray
    Write-Host '  после явного согласия человека.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  Итог:' -ForegroundColor White
Write-Host ('  {0,-24} {1,-24} {2,12}' -f 'ИМЯ', 'СТАТУС', 'ОСВОБОЖДЕНО') -ForegroundColor DarkGray
Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
foreach ($row in $report) {
    Write-Host ('  {0,-24} {1,-24} {2,12}' -f $row.Name, $row.Status, (Format-SizeText -Bytes $row.Freed))
    if ($row.Detail) {
        Write-Host ('  {0,-24} {1}' -f '', $row.Detail) -ForegroundColor DarkGray
    }
}

$totalFreed = ($report | Measure-Object -Property Freed -Sum).Sum
$freeAfter = Get-FreeSpaceBytes
Write-Host ''
Write-Host ('  Всего освобождено: {0}' -f (Format-SizeText -Bytes ([int64]$totalFreed))) -ForegroundColor Green
if ($null -ne $freeBefore -and $null -ne $freeAfter) {
    Write-Host ('  Свободно на C: {0} -> {1}' -f (Format-SizeText -Bytes $freeBefore), (Format-SizeText -Bytes $freeAfter)) -ForegroundColor Green
}
Write-Host ''
