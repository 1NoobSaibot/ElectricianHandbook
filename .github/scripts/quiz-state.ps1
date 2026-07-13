param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('init', 'select', 'update')]
    [string]$Command,

    [string]$BasePath = 'Перевірка Знань/Перша',
    [string]$StatePath = 'Перевірка Знань/Перша/Стан_опитування.json',
    [int]$Ticket,
    [int]$Question,
    [double]$Correctness,
    [double]$Completeness,
    [string]$Date,
    [string]$Summary
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-WorkspacePath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return $Path
    }
    return Join-Path (Get-Location) $Path
}

function Get-TicketDirectories {
    param([string]$Root)
    Get-ChildItem -Path $Root -Directory |
        Where-Object { $_.Name -like 'Квиток_*' } |
        Sort-Object { [int]($_.Name -replace 'Квиток_', '') }
}

function Get-QuestionCount {
    param([string]$QuestionFile)
    return (Get-Content $QuestionFile | Select-String '^\d+\. ').Count
}

function New-QuestionState {
    param([int]$Number)
    [ordered]@{
        question = $Number
        status = 'не питалось'
        attempts = 0
        correctness = 0.0
        completeness = 0.0
        score = 0.0
        lastDate = $null
    }
}

function Parse-ExistingTicketResults {
    param(
        [string]$ResultsFile,
        [int]$QuestionCount
    )

    $items = @{}
    for ($i = 1; $i -le $QuestionCount; $i++) {
        $items[$i] = New-QuestionState -Number $i
    }

    if (-not (Test-Path $ResultsFile)) {
        return $items
    }

    $lines = Get-Content $ResultsFile
    foreach ($line in $lines) {
        if ($line -match '^\|\s*(\d+)\s*\|\s*([^|]+)\|\s*(\d+)\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|\s*([^|]*)\|') {
            $number = [int]$Matches[1]
            if ($items.ContainsKey($number)) {
                $items[$number] = [ordered]@{
                    question = $number
                    status = $Matches[2].Trim()
                    attempts = [int]$Matches[3]
                    correctness = [double]$Matches[4]
                    completeness = [double]$Matches[5]
                    score = [double]$Matches[6]
                    lastDate = if ($Matches[7].Trim()) { $Matches[7].Trim() } else { $null }
                }
            }
        }
    }

    return $items
}

function Build-State {
    param([string]$Root)

    $tickets = @()
    foreach ($dir in Get-TicketDirectories -Root $Root) {
        $ticketNumber = [int]($dir.Name -replace 'Квиток_', '')
        $questionFile = Join-Path $dir.FullName 'Питання.md'
        $resultsFile = Join-Path $dir.FullName 'Результати_опитування.md'
        $questionCount = Get-QuestionCount -QuestionFile $questionFile
        $questionStates = Parse-ExistingTicketResults -ResultsFile $resultsFile -QuestionCount $questionCount

        $questions = @()
        for ($i = 1; $i -le $questionCount; $i++) {
            $questions += $questionStates[$i]
        }

        $tickets += [ordered]@{
            ticket = $ticketNumber
            path = $dir.FullName
            questionFile = $questionFile
            answerFile = Join-Path $dir.FullName 'Відповіді.md'
            resultsFile = $resultsFile
            questionCount = $questionCount
            questions = $questions
        }
    }

    return [ordered]@{
        version = 1
        updatedAt = (Get-Date).ToString('yyyy-MM-dd')
        basePath = $Root
        tickets = $tickets
    }
}

function Write-State {
    param(
        [hashtable]$State,
        [string]$Path
    )
    $json = $State | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($true)))
}

function Read-State {
    param([string]$Path)
    return Get-Content -Raw $Path | ConvertFrom-Json -Depth 8
}

function Get-TicketMetrics {
    param($TicketState)
    $questions = @($TicketState.questions)
    $scores = $questions | ForEach-Object { [double]$_.score }
    $asked = @($questions | Where-Object { $_.status -eq 'оцінено' })
    $unasked = @($questions | Where-Object { $_.status -ne 'оцінено' })
    $average = if ($scores.Count -gt 0) { [math]::Round((($scores | Measure-Object -Average).Average), 2) } else { 0.0 }
    $coverage = if ($questions.Count -gt 0) { [math]::Round(($asked.Count / $questions.Count) * 100, 1) } else { 0.0 }
    $weakQuestions = @($questions | Sort-Object score, question | Select-Object -First ([math]::Min(3, $questions.Count)) | ForEach-Object { $_.question })
    return [ordered]@{
        average = $average
        coverage = $coverage
        unaskedCount = $unasked.Count
        weakQuestions = $weakQuestions
        lastDate = (@($asked | Sort-Object lastDate -Descending | Select-Object -First 1).lastDate)[0]
    }
}

function Convert-WeakQuestionsToText {
    param([int[]]$Numbers)
    if (-not $Numbers -or $Numbers.Count -eq 0) {
        return ''
    }
    return ($Numbers | ForEach-Object { [string]$_ }) -join ', '
}

function Export-Markdown {
    param(
        $State,
        [string]$Root
    )

    $summaryLines = New-Object System.Collections.Generic.List[string]
    $summaryLines.Add('# Результати опитування по квитках')
    $summaryLines.Add('')
    $summaryLines.Add('## Правило агрегації')
    $summaryLines.Add('')
    $summaryLines.Add('- `Середній бал квитка` - середнє значення поля `Підсумок` по всіх питаннях квитка')
    $summaryLines.Add('- `Покриття` - частка питань зі статусом `оцінено`')
    $summaryLines.Add('- `Без результату` - кількість питань, які ще не ставились; вони враховуються в середньому як `0.0`')
    $summaryLines.Add('')
    $summaryLines.Add('| Квиток | Середній бал квитка | Покриття | Без результату | Найслабші питання | Наступний пріоритет | Остання дата |')
    $summaryLines.Add('| --- | --- | --- | --- | --- | --- | --- |')

    foreach ($ticket in $State.tickets) {
        $metrics = Get-TicketMetrics -TicketState $ticket
        $priority = if ($metrics.unaskedCount -gt 0) { 'найвищий' } elseif ($metrics.average -lt 0.5) { 'високий' } elseif ($metrics.average -lt 0.75) { 'середній' } else { 'низький' }
        $summaryLines.Add("| $($ticket.ticket) | $('{0:N2}' -f $metrics.average -replace ',', '.') | $($metrics.coverage)% | $($metrics.unaskedCount) | $(Convert-WeakQuestionsToText -Numbers $metrics.weakQuestions) | $priority | $($metrics.lastDate) |")

        $ticketLines = New-Object System.Collections.Generic.List[string]
        $ticketLines.Add('# Результати опитування по квитку')
        $ticketLines.Add('')
        $ticketLines.Add('## Шкала оцінювання')
        $ticketLines.Add('')
        $ticketLines.Add('- `0.0` - відповідь неправильна або відсутня')
        $ticketLines.Add('- `0.25` - вловлено лише окремі фрагменти')
        $ticketLines.Add('- `0.5` - відповідь частково правильна, але неповна')
        $ticketLines.Add('- `0.75` - відповідь переважно правильна, бракує деталей')
        $ticketLines.Add('- `1.0` - відповідь правильна і достатньо повна')
        $ticketLines.Add('')
        $ticketLines.Add('## Таблиця питань')
        $ticketLines.Add('')
        $ticketLines.Add('| Питання | Статус | Спроб | Правильність | Повнота | Підсумок | Остання дата |')
        $ticketLines.Add('| --- | --- | --- | --- | --- | --- | --- |')
        foreach ($question in $ticket.questions) {
            $ticketLines.Add("| $($question.question) | $($question.status) | $($question.attempts) | $('{0:0.##}' -f [double]$question.correctness) | $('{0:0.##}' -f [double]$question.completeness) | $('{0:0.##}' -f [double]$question.score) | $($question.lastDate) |")
        }
        $ticketLines.Add('')
        $ticketLines.Add('## Журнал спроб')
        $ticketLines.Add('')
        $ticketLines.Add('| Дата | Питання | Оцінка | Короткий висновок |')
        $ticketLines.Add('| --- | --- | --- | --- |')
        if ($ticket.PSObject.Properties.Name -contains 'history') {
            foreach ($entry in $ticket.history) {
                $ticketLines.Add("| $($entry.date) | $($entry.question) | $('{0:0.##}' -f [double]$entry.score) | $($entry.summary) |")
            }
        }
        [System.IO.File]::WriteAllText($ticket.resultsFile, ($ticketLines -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($true)))
    }

    [System.IO.File]::WriteAllText((Join-Path $Root 'Результати_по_квитках.md'), ($summaryLines -join [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($true)))
}

function Ensure-History {
    param($Ticket)
    if (-not ($Ticket.PSObject.Properties.Name -contains 'history')) {
        $Ticket | Add-Member -MemberType NoteProperty -Name history -Value @()
    }
}

function Initialize-State {
    $root = Resolve-WorkspacePath -Path $BasePath
    $stateFile = Resolve-WorkspacePath -Path $StatePath
    $state = Build-State -Root $root

    foreach ($ticket in $state.tickets) {
        $history = @()
        $resultsFile = $ticket.resultsFile
        if (Test-Path $resultsFile) {
            $lines = Get-Content $resultsFile
            foreach ($line in $lines) {
                if ($line -match '^\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*(\d+)\s*\|\s*([0-9.]+)\s*\|\s*(.*)\|\s*$') {
                    $history += [ordered]@{
                        date = $Matches[1]
                        question = [int]$Matches[2]
                        score = [double]$Matches[3]
                        summary = $Matches[4].Trim()
                    }
                }
            }
        }
        $ticket | Add-Member -MemberType NoteProperty -Name history -Value $history
    }

    Write-State -State $state -Path $stateFile
    Export-Markdown -State $state -Root $root
    $state | ConvertTo-Json -Depth 8
}

function Select-NextQuestion {
    $state = Read-State -Path (Resolve-WorkspacePath -Path $StatePath)
    $candidates = @()
    foreach ($ticket in $state.tickets) {
        foreach ($question in $ticket.questions) {
            $sortBucket = if ($question.status -ne 'оцінено') { 0 } else { 1 }
            $dateScore = if ($null -eq $question.lastDate -or $question.lastDate -eq '') { '1900-01-01' } else { [string]$question.lastDate }
            $candidates += [ordered]@{
                ticket = [int]$ticket.ticket
                question = [int]$question.question
                status = [string]$question.status
                score = [double]$question.score
                attempts = [int]$question.attempts
                lastDate = $dateScore
                sortBucket = $sortBucket
                questionFile = $ticket.questionFile
                answerFile = $ticket.answerFile
            }
        }
    }

    $pick = $candidates |
        Sort-Object sortBucket, score, lastDate, ticket, question |
        Select-Object -First 1

    $questionText = ''
    if ($pick) {
        $lines = Get-Content $pick.questionFile
        $match = $lines | Where-Object { $_ -match ("^$($pick.question)\\. ") } | Select-Object -First 1
        if ($match) {
            $questionText = $match -replace '^\d+\.\s*', ''
        }
    }

    [ordered]@{
        ticket = $pick.ticket
        question = $pick.question
        questionText = $questionText
        status = $pick.status
        score = $pick.score
        attempts = $pick.attempts
        answerFile = $pick.answerFile
    } | ConvertTo-Json -Depth 5
}

function Update-StateCommand {
    $root = Resolve-WorkspacePath -Path $BasePath
    $stateFile = Resolve-WorkspacePath -Path $StatePath
    $state = Read-State -Path $stateFile
    $ticketState = @($state.tickets | Where-Object { [int]$_.ticket -eq $Ticket })[0]
    if (-not $ticketState) {
        throw "Ticket $Ticket not found"
    }
    $questionState = @($ticketState.questions | Where-Object { [int]$_.question -eq $Question })[0]
    if (-not $questionState) {
        throw "Question $Question not found in ticket $Ticket"
    }

    $score = [math]::Round(($Correctness * 0.7) + ($Completeness * 0.3), 2)
    $questionState.status = 'оцінено'
    $questionState.attempts = [int]$questionState.attempts + 1
    $questionState.correctness = [math]::Round($Correctness, 2)
    $questionState.completeness = [math]::Round($Completeness, 2)
    $questionState.score = $score
    $questionState.lastDate = $Date

    Ensure-History -Ticket $ticketState
    $ticketState.history = @($ticketState.history) + @([ordered]@{
        date = $Date
        question = $Question
        score = $score
        summary = $Summary
    })

    $state.updatedAt = $Date
    Write-State -State $state -Path $stateFile
    Export-Markdown -State $state -Root $root

    [ordered]@{
        ticket = $Ticket
        question = $Question
        score = $score
        correctness = [math]::Round($Correctness, 2)
        completeness = [math]::Round($Completeness, 2)
        date = $Date
    } | ConvertTo-Json -Depth 5
}

switch ($Command) {
    'init' { Initialize-State }
    'select' { Select-NextQuestion }
    'update' { Update-StateCommand }
}