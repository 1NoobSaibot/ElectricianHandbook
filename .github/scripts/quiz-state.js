#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

function parseArgs(argv) {
  const args = { _: [] };
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith('--')) {
      args._.push(token);
      continue;
    }

    const key = token.slice(2);
    const next = argv[index + 1];
    if (next === undefined || next.startsWith('--')) {
      args[key] = true;
      continue;
    }

    args[key] = next;
    index += 1;
  }
  return args;
}

function workspacePath(inputPath) {
  if (path.isAbsolute(inputPath)) {
    return inputPath;
  }
  return path.join(process.cwd(), inputPath);
}

function readText(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

function writeText(filePath, content) {
  fs.writeFileSync(filePath, content, 'utf8');
}

function getTicketDirectories(root) {
  return fs
    .readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isDirectory() && entry.name.startsWith('Квиток_'))
    .sort((left, right) => {
      const leftNumber = Number(left.name.replace('Квиток_', ''));
      const rightNumber = Number(right.name.replace('Квиток_', ''));
      return leftNumber - rightNumber;
    })
    .map((entry) => path.join(root, entry.name));
}

function getQuestionCount(questionFile) {
  return readText(questionFile)
    .split(/\r?\n/)
    .filter((line) => /^\d+\.\s/.test(line)).length;
}

function newQuestionState(number) {
  return {
    question: number,
    status: 'не питалось',
    attempts: 0,
    correctness: 0,
    completeness: 0,
    score: 0,
    lastDate: null,
  };
}

function parseExistingTicketResults(resultsFile, questionCount) {
  const items = new Map();
  for (let number = 1; number <= questionCount; number += 1) {
    items.set(number, newQuestionState(number));
  }

  if (!fs.existsSync(resultsFile)) {
    return items;
  }

  const linePattern = /^\|\s*(\d+)\s*\|\s*([^|]+)\|\s*(\d+)\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|\s*([0-9.]+)\s*\|\s*([^|]*)\|?\s*$/;
  for (const line of readText(resultsFile).split(/\r?\n/)) {
    const match = line.match(linePattern);
    if (!match) {
      continue;
    }

    const number = Number(match[1]);
    if (!items.has(number)) {
      continue;
    }

    items.set(number, {
      question: number,
      status: match[2].trim(),
      attempts: Number(match[3]),
      correctness: Number(match[4]),
      completeness: Number(match[5]),
      score: Number(match[6]),
      lastDate: match[7].trim() || null,
    });
  }

  return items;
}

function parseExistingHistory(resultsFile) {
  const entries = [];
  if (!fs.existsSync(resultsFile)) {
    return entries;
  }

  const linePattern = /^\|\s*(\d{4}-\d{2}-\d{2})\s*\|\s*(\d+)\s*\|\s*([0-9.]+)\s*\|\s*(.*)\|\s*$/;
  for (const line of readText(resultsFile).split(/\r?\n/)) {
    const match = line.match(linePattern);
    if (!match) {
      continue;
    }

    entries.push({
      date: match[1],
      question: Number(match[2]),
      score: Number(match[3]),
      summary: match[4].trim(),
    });
  }

  return entries;
}

function buildState(root) {
  const tickets = [];
  for (const directory of getTicketDirectories(root)) {
    const ticketNumber = Number(path.basename(directory).replace('Квиток_', ''));
    const questionFile = path.join(directory, 'Питання.md');
    const resultsFile = path.join(directory, 'Результати_опитування.md');
    const questionCount = getQuestionCount(questionFile);
    const parsedQuestions = parseExistingTicketResults(resultsFile, questionCount);
    const questions = [];
    for (let number = 1; number <= questionCount; number += 1) {
      questions.push(parsedQuestions.get(number));
    }

    tickets.push({
      ticket: ticketNumber,
      path: directory,
      questionFile,
      answerFile: path.join(directory, 'Відповіді.md'),
      resultsFile,
      questionCount,
      questions,
      history: parseExistingHistory(resultsFile),
    });
  }

  return {
    version: 1,
    updatedAt: new Date().toISOString().slice(0, 10),
    basePath: root,
    tickets,
  };
}

function readState(statePath) {
  return JSON.parse(readText(statePath));
}

function writeState(state, statePath) {
  writeText(statePath, `${JSON.stringify(state, null, 2)}\n`);
}

function getTicketMetrics(ticket) {
  const scores = ticket.questions.map((question) => Number(question.score));
  const asked = ticket.questions.filter((question) => question.status === 'оцінено');
  const unasked = ticket.questions.filter((question) => question.status !== 'оцінено');
  const average = scores.length > 0
    ? Math.round((scores.reduce((sum, score) => sum + score, 0) / scores.length) * 100) / 100
    : 0;
  const coverage = ticket.questions.length > 0
    ? Math.round(((asked.length / ticket.questions.length) * 100) * 10) / 10
    : 0;
  const weakQuestions = [...ticket.questions]
    .sort((left, right) => left.score - right.score || left.question - right.question)
    .slice(0, Math.min(3, ticket.questions.length))
    .map((question) => question.question);
  const dated = asked
    .map((question) => question.lastDate)
    .filter(Boolean)
    .sort()
    .reverse();

  return {
    average,
    coverage,
    unaskedCount: unasked.length,
    weakQuestions,
    lastDate: dated[0] || '',
  };
}

function weakQuestionsToText(numbers) {
  return numbers.join(', ');
}

function exportMarkdown(state, root) {
  const summaryLines = [
    '# Результати опитування по квитках',
    '',
    '## Правило агрегації',
    '',
    '- `Середній бал квитка` - середнє значення поля `Підсумок` по всіх питаннях квитка',
    '- `Покриття` - частка питань зі статусом `оцінено`',
    '- `Без результату` - кількість питань, які ще не ставились; вони враховуються в середньому як `0.0`',
    '',
    '| Квиток | Середній бал квитка | Покриття | Без результату | Найслабші питання | Наступний пріоритет | Остання дата |',
    '| --- | --- | --- | --- | --- | --- | --- |',
  ];

  for (const ticket of state.tickets) {
    const metrics = getTicketMetrics(ticket);
    const priority = metrics.unaskedCount > 0
      ? 'найвищий'
      : metrics.average < 0.5
        ? 'високий'
        : metrics.average < 0.75
          ? 'середній'
          : 'низький';

    summaryLines.push(
      `| ${ticket.ticket} | ${metrics.average.toFixed(2)} | ${metrics.coverage}% | ${metrics.unaskedCount} | ${weakQuestionsToText(metrics.weakQuestions)} | ${priority} | ${metrics.lastDate} |`,
    );

    const ticketLines = [
      '# Результати опитування по квитку',
      '',
      '## Шкала оцінювання',
      '',
      '- `0.0` - відповідь неправильна або відсутня',
      '- `0.25` - вловлено лише окремі фрагменти',
      '- `0.5` - відповідь частково правильна, але неповна',
      '- `0.75` - відповідь переважно правильна, бракує деталей',
      '- `1.0` - відповідь правильна і достатньо повна',
      '',
      '## Таблиця питань',
      '',
      '| Питання | Статус | Спроб | Правильність | Повнота | Підсумок | Остання дата |',
      '| --- | --- | --- | --- | --- | --- | --- |',
    ];

    for (const question of ticket.questions) {
      ticketLines.push(
        `| ${question.question} | ${question.status} | ${question.attempts} | ${Number(question.correctness).toFixed(2).replace(/\.00$/, '.0').replace(/(\.\d)0$/, '$1')} | ${Number(question.completeness).toFixed(2).replace(/\.00$/, '.0').replace(/(\.\d)0$/, '$1')} | ${Number(question.score).toFixed(2).replace(/\.00$/, '.0').replace(/(\.\d)0$/, '$1')} | ${question.lastDate || ''} |`,
      );
    }

    ticketLines.push('', '## Журнал спроб', '', '| Дата | Питання | Оцінка | Короткий висновок |', '| --- | --- | --- | --- |');
    for (const entry of ticket.history || []) {
      const scoreText = Number(entry.score).toFixed(2).replace(/\.00$/, '.0').replace(/(\.\d)0$/, '$1');
      ticketLines.push(`| ${entry.date} | ${entry.question} | ${scoreText} | ${entry.summary} |`);
    }

    writeText(ticket.resultsFile, `${ticketLines.join('\n')}\n`);
  }

  writeText(path.join(root, 'Результати_по_квитках.md'), `${summaryLines.join('\n')}\n`);
}

function initializeState(options) {
  const root = workspacePath(options.basePath);
  const statePath = workspacePath(options.statePath);
  const state = buildState(root);
  writeState(state, statePath);
  exportMarkdown(state, root);
  process.stdout.write(`${JSON.stringify(state, null, 2)}\n`);
}

function selectNextQuestion(options) {
  const state = readState(workspacePath(options.statePath));
  const candidates = [];
  for (const ticket of state.tickets) {
    for (const question of ticket.questions) {
      candidates.push({
        ticket: Number(ticket.ticket),
        question: Number(question.question),
        status: String(question.status),
        score: Number(question.score),
        attempts: Number(question.attempts),
        lastDate: question.lastDate || '1900-01-01',
        sortBucket: question.status === 'оцінено' ? 1 : 0,
        questionFile: ticket.questionFile,
        answerFile: ticket.answerFile,
      });
    }
  }

  candidates.sort((left, right) => (
    left.sortBucket - right.sortBucket
    || left.score - right.score
    || left.lastDate.localeCompare(right.lastDate)
    || left.ticket - right.ticket
    || left.question - right.question
  ));

  const pick = candidates[0];
  let questionText = '';
  if (pick) {
    const line = readText(pick.questionFile)
      .split(/\r?\n/)
      .find((entry) => new RegExp(`^${pick.question}\\. `).test(entry));
    if (line) {
      questionText = line.replace(/^\d+\.\s*/, '');
    }
  }

  process.stdout.write(`${JSON.stringify({
    ticket: pick.ticket,
    question: pick.question,
    questionText,
    status: pick.status,
    score: pick.score,
    attempts: pick.attempts,
    answerFile: pick.answerFile,
  }, null, 2)}\n`);
}

function updateState(options) {
  const root = workspacePath(options.basePath);
  const statePath = workspacePath(options.statePath);
  const state = readState(statePath);
  const ticketNumber = Number(options.ticket);
  const questionNumber = Number(options.question);
  const correctness = Math.round(Number(options.correctness) * 100) / 100;
  const completeness = Math.round(Number(options.completeness) * 100) / 100;
  const score = Math.round(((correctness * 0.7) + (completeness * 0.3)) * 100) / 100;

  const ticket = state.tickets.find((entry) => Number(entry.ticket) === ticketNumber);
  if (!ticket) {
    throw new Error(`Ticket ${ticketNumber} not found`);
  }

  const question = ticket.questions.find((entry) => Number(entry.question) === questionNumber);
  if (!question) {
    throw new Error(`Question ${questionNumber} not found in ticket ${ticketNumber}`);
  }

  question.status = 'оцінено';
  question.attempts = Number(question.attempts) + 1;
  question.correctness = correctness;
  question.completeness = completeness;
  question.score = score;
  question.lastDate = options.date;

  if (!Array.isArray(ticket.history)) {
    ticket.history = [];
  }

  ticket.history.push({
    date: options.date,
    question: questionNumber,
    score,
    summary: options.summary || '',
  });

  state.updatedAt = options.date;
  writeState(state, statePath);
  exportMarkdown(state, root);

  process.stdout.write(`${JSON.stringify({
    ticket: ticketNumber,
    question: questionNumber,
    score,
    correctness,
    completeness,
    date: options.date,
  }, null, 2)}\n`);
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const command = args._[0];
  const options = {
    basePath: args.basePath || 'Перевірка Знань/Перша',
    statePath: args.statePath || 'Перевірка Знань/Перша/Стан_опитування.json',
    ticket: args.ticket,
    question: args.question,
    correctness: args.correctness,
    completeness: args.completeness,
    date: args.date,
    summary: args.summary,
  };

  if (!['init', 'select', 'update'].includes(command)) {
    throw new Error('Expected one of: init, select, update');
  }

  if (command === 'init') {
    initializeState(options);
    return;
  }

  if (command === 'select') {
    selectNextQuestion(options);
    return;
  }

  updateState(options);
}

main();