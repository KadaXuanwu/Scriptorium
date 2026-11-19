// The queue app's page (docs/APP.md): renders every project's /api/state every 10 s while visible, posts the owner's
// actions.
'use strict';

const $ = (id) => document.getElementById(id);
// One page shows every project that Scriptorium runs on the PC (docs/APP.md, Projects). `fresh` holds the last
// snapshot of each project as its server sent it, by the project's name; `states` holds what the page shows: each
// snapshot with the owner's unconfirmed actions on top. `home` is the project of this address, `projects` the PC's
// projects with their addresses (from this address's snapshot), `names` those that have a snapshot.
let fresh = {};
let states = {};
let home = '';
let projects = [];
let names = [];
// The project in scope and its snapshot: the one whose item the page draws now (within). Two projects can have a
// ticket 12 and a question of the same key, so an item is drawn, looked up and changed in its own project's
// snapshot only, and an action names its project itself (act).
let scope = '';
let state = null;
let fetches = 0;
// The count of the fetch that brought each project's snapshot.
const seen = {};
// The owner's actions that the server's state does not show yet, by project and the card each one changes. The page
// shows an action at once and marks its card busy until a snapshot of its project confirms it. Each: project, apply
// (the change, shown from the click), after (a change shown once the server said yes), done (true when a snapshot
// shows the action; without it, the first snapshot fetched after the yes confirms), responded, seq (the fetch count
// at the yes), until.
const ops = new Map();
const busyClass = (key) => (ops.has(`${scope}|${key}`) ? ' busy' : '');
const busyAttr = (key) => (ops.has(`${scope}|${key}`) ? ' inert aria-busy="true"' : '');
const workerOf = (s, id) => s.workers.find((w) => w.id === id);
const accountOf = (s, name) => s.accounts.find((a) => a.name === name);
const complexityOf = (s, name) => (s.complexities || []).find((c) => c.name === name);
const rowOf = (s, number) => [...s.queued, ...s.parked].find((row) => row.number === number);

// Redraws a list only when it changed and holds no field in use, so typing, the phone keyboard and open folds
// survive the 10 s refresh.
const drawn = new WeakMap();
function put(el, html) {
  const active = document.activeElement;
  if (el.contains(active) && active.matches('textarea, select, input')) return;
  if (drawn.get(el) === html) return;
  const open = [...el.querySelectorAll('details[open][data-key]')].map((d) => d.dataset.key);
  el.innerHTML = html;
  drawn.set(el, html);
  for (const key of open) el.querySelector(`details[data-key="${CSS.escape(key)}"]`)?.setAttribute('open', '');
}

const esc = (text) => String(text ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const icon = (name) => `<svg class="i" aria-hidden="true"><use href="#i-${name}"/></svg>`;

// Draws with a project in scope.
function within(project, draw) {
  const before = [scope, state];
  scope = project;
  state = states[project];
  try {
    return draw();
  } finally {
    [scope, state] = before;
  }
}
// An item's HTML with its project on its first tag, so a click on the item finds the project (projectOf).
const tagged = (project, html) => html.replace(/<[a-z]+/, (tag) => `${tag} data-project="${esc(project)}"`);
const projectOf = (el) => el.closest('[data-project]')?.dataset.project || home;
// One list of every project (`field` of each snapshot), each item with its project; and its items drawn, each in its
// own project's scope.
const all = (field) => names.flatMap((p) => (states[p]?.[field] || []).map((item) => ({ p, item })));
const drawEach = (list, template) => list.map(({ p, item }) => within(p, () => tagged(p, template(item)))).join('');
// A project's mark on an item, while the PC has two projects or more: its name, in a colour of its own.
const hue = (name) => [...name].reduce((sum, c) => (sum * 31 + c.charCodeAt(0)) % 360, 7);
// The colour of hue() (65 % saturation, 50 % lightness) as #rrggbb: a colour field takes no other form.
function hueHex(name) {
  const h = hue(name);
  const a = 0.65 * 0.5;
  const part = (n) => {
    const k = (n + h / 30) % 12;
    return Math.round(255 * (0.5 - a * Math.max(-1, Math.min(k - 3, 9 - k, 1)))).toString(16).padStart(2, '0');
  };
  return `#${part(0)}${part(8)}${part(4)}`;
}
// A project's colour: the one Details set (`color`), else the one from its name. Checked again here before it goes
// into a style attribute: a hand edit of the settings file skips the server's check.
const ownColor = (s) => (/^#[0-9a-f]{6}$/i.test(s?.color || '') ? s.color : '');
const colorOf = (project) => ownColor(states[project]) || hueHex(project);
const mark = () => (names.length > 1 ? `<span class="badge of" style="--of:${colorOf(scope)}">${esc(scope)}</span>` : '');

function duration(seconds) {
  if (seconds == null) return '';
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min`;
  const hours = Math.floor(minutes / 60);
  return `${hours} h ${String(minutes % 60).padStart(2, '0')}`;
}

const ago = (unix) => `${duration(Math.max(0, state.now - unix))} ago`;
const clock = (time) => new Date(time).toLocaleString([], { weekday: 'short', hour: '2-digit', minute: '2-digit' });
const percent = (share) => `${Math.round((share ?? 0) * 100)}\u00a0%`; // a no-break space: never apart from its number
const dollars = (cost) => `$${Math.round(cost)}`;

function modelName(id) {
  const match = /claude-(\w+)-(\d+)-(\d+)/.exec(id || '');
  return match ? `${match[1][0].toUpperCase()}${match[1].slice(1)} ${match[2]}.${match[3]}` : (id || '');
}

// Questions and tickets arrive as markdown: links, bold, code, italics and line breaks are enough to read them. A link
// into the repo has no address the page can open, so it shows as its text. A bare address is a link too; a GitHub
// issue or PR address shows as repo#N, as GitHub shows it. A question's picture on its shots branch (shots.ps1)
// shows as the picture, from the server (the repo is private); a tap opens it whole.
function markdown(text) {
  return esc(text)
    .replace(/!\[([^\]]*)\]\(https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/blob\/(shots-t\d+)\/([\w.-]+\.(?:png|jpe?g))(?:\?raw=true)?\)/gi,
      (all, alt, branch, name) => {
        const src = `${api(scope, 'api/shot')}?branch=${branch}&amp;name=${name}`;
        return `<a class="shot" href="${src}" target="_blank"><img src="${src}" alt="${alt}" loading="lazy"></a>`;
      })
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)|(https:\/\/[^\s<]*[^\s<.,;:!?)\]])/g, (all, label, href, bare) => {
      if (bare) {
        const issue = /^https:\/\/github\.com\/[^/]+\/([^/]+)\/(?:pull|issues)\/(\d+)$/.exec(bare);
        return `<a href="${bare}" target="_blank">${issue ? `${issue[1]}#${issue[2]}` : bare}</a>`;
      }
      return /^https:\/\//.test(href) ? `<a href="${href}" target="_blank">${label}</a>` : label;
    })
    .replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<i>$2</i>')
    .replace(/\n/g, '<br>');
}

const badges = (items) => (items || []).filter(Boolean).map((a) => `<span class="badge">${esc(a)}</span>`).join('');
// A ticket's tags stand in one order on every tab: kind, repo, areas, size, then the model and effort of its run (Now,
// History) or, for a ticket not started, its complexity (Next, Queue).
const runModel = (t) => t.model && `${modelName(t.model)}${t.effort ? ` · ${t.effort}` : ''}`;

// ---- Workers

const statusNames = { active: 'Active', paused: 'Paused', disabled: 'Disabled' };
const statusIcons = { active: 'play', paused: 'pause', disabled: 'power' };
const pendingVerbs = { paused: 'Pauses', disabled: 'Disables' };
const howNames = { finish: 'after the ticket', checkpoint: 'at the next checkpoint' };
// Why an account is out, on its card and on the cards of its workers.
const outNames = { login: 'Account signed out', subscription: 'Subscription refused', start: 'Runs do not start' };

// An account that takes no runs says so in an account list, before the owner gives it a worker.
const outMark = { signedout: ' (signed out)', refused: ' (takes no runs)' };

// Adding and removing: a tile at the end of the Workers and the Accounts list adds one, the
// cross at the top right of a card removes it. Each asks first, in the same dialog (ask).
const addTile = (kind, label) => `<button class="add-tile" data-add="${kind}">${icon('plus')}<span>${label}</span></button>`;
const cross = (kind, key, name) => `<button class="x" data-remove="${kind}" data-name="${esc(key)}" title="Remove ${esc(name)}" aria-label="Remove ${esc(name)}">${icon('x')}</button>`;

// What the worker does now: a tone, an icon and a few words.
function activity(worker) {
  if (worker.activity === 'down') return ['bad', 'alert', `Script silent for ${duration(state.now - worker.at)}`];
  // A worker the owner added: the server makes its clone, then its plugins make its environment ready, in their own
  // words (a first import can take long).
  if (worker.activity === 'setup') return ['muted', 'history', 'Setting up its copy of the repo'];
  if (worker.activity === 'opening') return ['muted', 'history', esc(worker.report || 'Getting its environment ready')];
  if (worker.activity === 'setup-failed') return ['bad', 'alert', 'Setup failed'];
  // A plugin's hook threw (its text is in Now); the worker tries again at its next look.
  if (worker.activity === 'error') return ['bad', 'alert', 'Its environment failed'];
  // Its account is out (docs/QUEUE.md, An account that is out): the cause, and when the workers test the account next.
  // `own`: its runs do not start although its account answers, so the cause is on this card (Now), not on Accounts.
  if (worker.activity === 'signedout') {
    const out = worker.out || {};
    const retry = out.retryAt ? ` · next test ${clock(out.retryAt * 1000)}` : '';
    const words = outNames[out.kind] || outNames.login;
    return ['bad', 'alert', `${out.own ? `<span title="${esc(out.text)}">${words}</span>` : `<a href="#accounts" title="${esc(out.text)}">${words}</a>`}${retry}`];
  }
  // 'held': its run ended at a checkpoint for the owner's pause and waits, with its session, for the worker to be active.
  if (worker.status === 'active' && ['resuming', 'held'].includes(worker.activity)) return ['good', 'play', 'Resumes within a minute'];
  // A worker that is not active waits for nothing: its status says it all.
  if (worker.status === 'active' && worker.activity === 'limit') return ['warn', 'history', `Usage limit · resumes ${clock(worker.resetsAt * 1000)}`];
  if (worker.status === 'active' && worker.activity === 'room') return ['warn', 'history', '<a href="#accounts">Account at its stop line</a>'];
  if (worker.activity === 'running') {
    const job = { answered: 'Applying your answers', 'needs-rebase': 'Rebasing its PR' }[worker.kind];
    return ['good', 'play', job ? `<a href="${esc(worker.prUrl)}" target="_blank">${job}</a>` : 'Working'];
  }
  return ['muted', statusIcons[worker.status], worker.status === 'active' ? 'Free' : statusNames[worker.status]];
}

// The run's time against a typical run of its size: the fill is the share worked, a mark shows a run held at its limit.
function progressBar(worker) {
  if (!worker.run) return '';
  const elapsed = worker.startedAt ? state.now - worker.startedAt : (worker.elapsed || 0);
  const held = !worker.startedAt;
  const over = worker.typical && elapsed > worker.typical;
  const share = worker.typical ? Math.min(1, elapsed / worker.typical) : 0.12;
  // A run past its usual time still works: its bar stays in the working colour, and the line under it says so.
  const kinds = [held ? 'held' : '', worker.typical ? '' : 'unknown'].join(' ');
  let right = 'no estimate yet';
  if (worker.typical) {
    right = over ? `past its usual ${duration(worker.typical)}` : `about ${duration(worker.typical - elapsed)} left`;
    if (worker.typicalCost) right += ` · ≈ ${dollars(worker.typicalCost)}`;
  }
  const steps = worker.progress
    ? `<div class="checkpoint"><span>${icon('check')}${esc(worker.progress.done)}</span><span>${icon('next')}${esc(worker.progress.next)}</span></div>` : '';
  return `<div class="prog ${kinds}" role="img" aria-label="Ticket progress, an estimate">
      <div class="fill" style="width:${share * 100}%"></div>${held ? `<div class="mark" style="left:${share * 100}%">${icon('pause')}</div>` : ''}</div>
    <div class="prog-meta"><span>${held ? `held${elapsed ? ` at ${duration(elapsed)}` : ''}` : duration(elapsed)}</span><span>${right}</span></div>${steps}`;
}

// The workers whose details are open. Only where the cards stand in one column: there a card shows its last
// checkpoint and its next ticket after a press on the arrow in its head (style.css). Side by side, every card shows all.
const opened = new Set();
function workerCard(worker) {
  const id = esc(worker.id);
  const open = opened.has(`${scope}|${worker.id}`);
  const [tone, glyph, words] = activity(worker);
  const repo = worker.repo && worker.repo !== state.slug ? [worker.repo.split('/')[1]] : [];
  const now = worker.ticket
    ? `<a class="title" href="${esc(worker.url)}" target="_blank">${esc(worker.title || `Ticket ${worker.ticket}`)}</a>
       <div class="meta">${badges([...repo, ...(worker.areas || []), worker.size, runModel(worker), worker.heldOn && `held on ${worker.heldOn}`])}</div>${progressBar(worker)}`
    : `<span class="free">${esc(worker.out?.text || worker.error || 'Free')}</span>`;

  // Force moves the next ticket into the free slot now, also one the queue would not give it.
  const next = worker.next;
  let force = '';
  if (worker.forced && !worker.run) force = `<button data-unforce="${id}">Cancel</button>`;
  else if (next) {
    const can = worker.status === 'active' && !worker.run && !['down', 'signedout', 'setup', 'setup-failed', 'error'].includes(worker.activity);
    force = `<button class="round" data-force="${id}" title="${can ? 'Take it now' : 'Its slot is not free'}" aria-label="Take it now"${can ? '' : ' disabled'}>${icon('up')}</button>`;
  }
  const kind = next && { answered: 'your answers', 'needs-rebase': 'a rebase' }[next.kind];
  const nextBody = next
    ? `<a class="title${next.available ? '' : ' off'}" href="${esc(next.url)}" target="_blank">${esc(next.title)}</a>
       <div class="meta">${badges([kind, ...(next.areas || []), next.size, next.complexity])}${worker.forced && !worker.run ? '<span class="why">takes it at its next poll</span>'
    : next.available ? '' : `<span class="why">${icon('lock')}${esc(next.why)}</span>`}</div>`
    : `<span class="free">${worker.status === 'disabled' ? 'None' : 'Nothing queued'}</span>`;

  const seg = Object.keys(statusNames).map((s) => `<button data-status="${s}" data-worker="${id}" aria-pressed="${worker.status === s}"
    class="${worker.status === s ? 'on' : ''}${worker.pending?.to === s ? ' pending' : ''}"${worker.status === s ? ` style="view-transition-name:seg-${esc(scope)}-${id}"` : ''}>${icon(statusIcons[s])}<span>${statusNames[s]}</span></button>`).join('');
  const pending = worker.pending ? `<div class="pending-note">${pendingVerbs[worker.pending.to]} ${howNames[worker.pending.how]}</div>` : '';

  // Config opens the worker's config (drawConfig). Its button counts the complexities the worker takes while one is off.
  const all = worker.takes || [];
  const on = all.filter((t) => t.on).length;
  const config = `<button class="config-open" data-config="${id}" aria-label="Config of worker ${id}">${icon('config')}Config${on < all.length ? ` <small>${on}/${all.length}</small>` : ''}</button>`;

  const accounts = state.accounts || [];
  const options = accounts.map((a) => `<option value="${esc(a.name)}"${a.name === worker.account ? ' selected' : ''}>${esc(a.name)}${outMark[a.status] || ''}</option>`);
  // A worker in no entry runs on the command-line login; offered only while no entry is that login.
  if (!worker.account || accounts.every((a) => a.own)) options.unshift(`<option value=""${worker.account ? '' : ' selected'}>command line</option>`);

  // Its project, while the PC has two or more: the mark is a choice that moves it to another project (`data.move`).
  const fixed = worker.run || worker.ticket ? 'It has a ticket: disable it first, then move it'
    : worker.activity === 'setup' ? 'Its setup still runs' : '';
  const project = names.length > 1
    ? `<select class="badge of" style="--of:${colorOf(scope)}" data-move="${id}" aria-label="Project of worker ${id}"${fixed ? ` disabled title="${fixed}"` : ''}>${
      names.map((p) => `<option${p === scope ? ' selected' : ''}>${esc(p)}</option>`).join('')}</select>` : '';

  const card = `worker:${worker.id}`;
  return `<article class="card worker ${esc(worker.status)}${open ? ' open' : ''}${busyClass(card)}"${busyAttr(card)}>
    <div class="worker-head"><span class="avatar">${id}</span><div class="who"><strong>Worker ${id}${project}</strong>
      <span class="doing ${tone}">${icon(glyph)}${words}</span></div>
      <button class="round more" data-more="${id}" aria-expanded="${open}" aria-label="Details of worker ${id}">${icon('down')}</button>${cross('worker', id, `worker ${id}`)}</div>
    <div class="status"><div class="seg" role="group" aria-label="Status of worker ${id}">${seg}</div>${pending}</div>
    <div class="worker-tools"><label>${icon('accounts')}<select data-assign="${id}" aria-label="Account of worker ${id}">${options.join('')}</select></label>
      ${config}<button data-steps="${id}">${icon('steps')}Steps</button></div>
    <div class="slot now"><span class="slot-label">Now</span><div class="slot-body">${now}</div></div>
    <div class="slot next"><span class="slot-label">Next</span><div class="slot-body">${nextBody}</div>${force}</div></article>`;
}

// A worker's config, the dialog its Config button opens: a switch for each complexity (docs/QUEUE.md, Settings,
// `workers.<id>.complexity`). Off, the worker takes no new ticket of the complexity and leaves the answers and rebases
// of its PRs of it (`jobs`) until it is on again. What is the same for every worker of the project is on Details.
let configOf = null;
function drawConfig() {
  const worker = configOf && states[configOf.project] && workerOf(states[configOf.project], configOf.id);
  if (!worker) { $('config').close(); return; }
  within(configOf.project, () => drawConfigOf(worker));
}
function drawConfigOf(worker) {
  const id = esc(worker.id);
  $('config-title').textContent = `Worker ${worker.id}${names.length > 1 ? ` on ${scope}` : ''}: config`;
  put($('config-body'), `<div class="takes">${(worker.takes || []).map((t) => {
    const name = esc(t.name);
    const jobs = !t.on && t.jobs ? `<small>holds ${t.jobs} PR job${t.jobs === 1 ? '' : 's'}</small>` : '';
    return `<button class="take${t.on ? ' on' : ''}" data-take="${name}" data-worker="${id}" aria-pressed="${t.on}">
      ${icon(t.on ? 'check' : 'lock')}<span><b>${name}</b>${jobs}</span></button>`;
  }).join('')}</div>
    <p class="takes-note">Details sets the model, the effort, the compact size and the advisor of each complexity, for all workers.</p>`);
}

// ---- Details: the settings

// The settings that are the same for all workers of a project (docs/APP.md, Details), one block for each project,
// drawn in its scope. A row for each complexity: its model and effort (`complexities.<name>.model`), its compact size
// (`.compactAt`), its advisor switch (`.advisor`) and its effort without the advisor (`.advisorFallback`). The lists
// are models.json's, with the value in use always among them: a list without it would show its first entry. The
// models have the base's own too (`base`, which a project may name outside the list), so the way back is always
// there. A pick that is not the base's shows the base's under it. Each field has a fallback for an older snapshot.
const pickList = (list, value, label) => [...new Set([...list, value])].filter(Boolean)
  .map((v) => `<option value="${esc(v)}"${v === value ? ' selected' : ''}>${esc(label(v))}</option>`).join('');
// At most 17 letters: a phone cuts a longer entry in its list (168 px wide at 375 px).
const fallbackName = (effort) => `${effort || 'same'} without it`;

function complexityRow(c) {
  const name = esc(c.name);
  const key = `complexity:${c.name}`;
  const advisorModel = state.advisor?.model;
  const on = c.advisorOn ?? Boolean(c.advisor);
  const fallback = c.advisorFallback || '';
  const notes = [c.base && (c.base.model !== c.model || c.base.effort !== c.effort)
    && `Default: ${esc(modelName(c.base.model))} · ${esc(c.base.effort)}`,
  c.baseAdvisor != null && (c.baseAdvisor !== on || (c.baseFallback || '') !== fallback)
    && `Default: ${c.baseAdvisor ? `advisor, ${esc(fallbackName(c.baseFallback))}` : 'no advisor'}`].filter(Boolean);
  const advisor = c.model === advisorModel
    ? '<small>No advisor: the run is on the advisor\'s model.</small>'
    : `<button class="take${on ? ' on' : ''}" data-advisor="${name}" aria-pressed="${on}" aria-label="Advisor of a ${name} run">${icon(on ? 'check' : 'lock')}<span><b>Advisor</b></span></button>
      <select data-fallback="${name}" aria-label="Effort of a ${name} run without the advisor"${on ? '' : ' disabled'}>${
  ['', ...(state.efforts || [])].map((e) => `<option value="${esc(e)}"${e === fallback ? ' selected' : ''}>${esc(fallbackName(e))}</option>`).join('')}</select>`;
  // The description is behind an (i) button: a popover that a tap outside closes, so a phone keeps the row short.
  const about = esc(`about-${scope}-${c.name}`);
  return `<div class="config-row${busyClass(key)}"${busyAttr(key)}>
    <span class="config-name"><b>${name}<button class="about" popovertarget="${about}" aria-label="What ${name} is">${icon('info')}</button></b>
      <span class="pop about-text" id="${about}" popover>${esc(c.description)}</span></span>
    <select data-run-model="${name}" aria-label="Model of a ${name} run">${pickList([...(state.models || []), c.base?.model], c.model, modelName)}</select>
    <select data-run-effort="${name}" aria-label="Effort of a ${name} run">${pickList(state.efforts || [], c.effort, (v) => v)}</select>
    <label class="compact"><input type="number" inputmode="numeric" min="67" max="967" step="1" value="${Math.round(c.compactAt / 1000)}"
      data-compact="${name}" aria-label="Thousands of tokens at which a ${name} run compacts its context">k tokens</label>
    ${notes.length ? `<small>${notes.join(' · ')}</small>` : ''}${advisor}</div>`;
}

function settingsBlock() {
  const advisor = state.advisor || {};
  const base = advisor.base || advisor.model;
  // The colour shows only on the marks, and a PC with one project shows none.
  const head = names.length > 1 ? `<div class="settings-head${busyClass('color')}"${busyAttr('color')}><h2>${mark()}</h2>
    <input type="color" value="${colorOf(scope)}" data-color="${esc(scope)}" aria-label="Colour of ${esc(scope)}">
    ${ownColor(state) ? '<button data-color-reset>Default colour</button>' : ''}</div>` : '';
  const [model, effort] = (state.settingsModel || '').split('@');
  const override = model ? `<p class="settings-note">settings.json sets ${esc(modelName(model))}${effort ? ` · ${esc(effort)}` : ''}
    for every run: the models and efforts above are not in use.</p>` : '';
  return `<section class="settings">${head}
    <div class="config-head"><span>Complexity</span><span>Model, effort, compacts near</span></div>
    ${(state.complexities || []).map(complexityRow).join('')}
    <div class="config-row${busyClass('advisor-model')}"${busyAttr('advisor-model')}><span class="config-name"><b>Advisor</b><small>Its model</small></span>
      <select data-advisor-model aria-label="Model of the advisor">${pickList(state.models || [], advisor.model, modelName)}</select>
      ${base && base !== advisor.model ? `<small>Default: ${esc(modelName(base))}</small>` : ''}</div>
    ${override}<p class="settings-note">A change counts from the next run. A run in progress or on hold keeps its model, its effort and its advisor.</p></section>`;
}

// ---- Questions

const questionTags = { pr: 'Holds a PR', ticket: 'Holds a ticket', question: 'Default is built', followup: 'New work' };

function questionCard(q) {
  const key = esc(q.key);
  const details = q.details
    ? `<details data-key="more-${esc(scope)}-${key}"><summary>More</summary><div class="text">${markdown(q.details)}</div></details>` : '';
  const tag = questionTags[q.kind] + (q.kind === 'followup' && q.size ? ` · size ${esc(q.size)}` : '');
  const card = `question:${q.key}`;
  return `<article class="card question${q.blocking ? ' blocking' : ''}${busyClass(card)}"${busyAttr(card)}>
    <div class="question-head"><span class="tag">${tag}</span>${mark()}<a href="${esc(q.url)}" target="_blank">${esc(q.title)}</a></div>
    <div class="text ask">${markdown(q.question)}</div>${details}
    <textarea data-key="${key}" rows="2" placeholder="${q.kind === 'followup' ? 'Your answer. &quot;No&quot; drops it.' : 'Your answer'}"></textarea>
    <div class="buttons"><button data-default="${key}">Accept default</button><button class="primary" data-answer="${key}">Send answer</button></div></article>`;
}

// ---- Queue

function prioritySelect(row) {
  const options = ['P0', 'P1', 'P2', 'park'].map((p) => `<option value="${p}"${(row.priority || 'park') === p ? ' selected' : ''}>${p === 'park' ? 'parked' : p}</option>`);
  return `<select data-priority="${row.number}" aria-label="Priority">${options.join('')}</select>`;
}

function ticketRow(row) {
  const estimate = row.seconds ? `<span class="estimate">≈ ${duration(row.seconds)}${row.cost ? ` · ${dollars(row.cost)}` : ''}</span>` : '';
  const ready = row.reason === 'next up';
  const reason = row.reason ? `<span class="why${ready ? ' good' : ''}">${icon(ready ? 'next' : 'lock')}${esc(row.reason)}</span>` : '';
  const card = `ticket:${row.number}`;
  return `<div class="row${busyClass(card)}"${busyAttr(card)}><div class="what"><a href="${esc(row.url)}" target="_blank">${esc(row.title)}</a>
    <div class="meta">${mark()}${badges([row.repo, ...(row.areas || []), row.size, row.complexity])}${estimate}${reason}</div></div>${prioritySelect(row)}</div>`;
}


const stuckRow = (item) => `<div class="row${busyClass(`stuck:${item.key}`)}"${busyAttr(`stuck:${item.key}`)}><div class="what"><a href="${esc(item.url)}" target="_blank">${esc(item.title)}</a>
  <div class="meta">${mark()}${badges([item.worker && `worker ${item.worker}`])}</div><div class="reason">${markdown(item.reason)}</div></div>
  <button data-retry="${esc(item.key)}">${icon('retry')}Retry</button></div>`;

const heldRow = (item) => `<div class="row"><div class="what"><a href="${esc(item.url)}" target="_blank">${esc(item.title)}</a>
  <div class="meta">${mark()}</div></div></div>`;

// ---- History

const mergedRow = (m) => `<div class="row"><div class="what"><a href="${esc(m.url)}" target="_blank">${esc(m.title)}</a>
  <div class="meta">${mark()}</div></div><span class="when">${esc(clock(m.mergedAt))}</span></div>`;

function runRow(r) {
  const kind = { answered: 'answers', 'needs-rebase': 'rebase' }[r.kind] || (r.partial ? 'part' : '');
  return `<div class="row"><div class="what">${esc(r.title || `Ticket ${r.ticket}`)}
    <div class="meta">${mark()}${badges([kind, r.size, modelName(r.model), r.duration && duration(r.duration), r.cost != null && `$${Number(r.cost).toFixed(2)}`])}</div></div>
    <span class="when">${ago(r.at)}</span></div>`;
}

// ---- Accounts

const accountStates = {
  ready: ['good', 'check', 'Ready'], limit: ['warn', 'history', 'At its stop line'],
  signedout: ['bad', 'alert', 'Signed out'], unused: ['muted', 'pause', 'Not used'],
  // Out for another cause than its login: the chip names it (outNames), the card gives the refusal's text.
  refused: ['bad', 'alert', 'Takes no runs'],
};

// The Fable week's key (limits.ps1, $FableWindow): only a Fable request reads it, and it has its own stop line. From
// there no worker starts a Fable run on the account and no run gets the Fable advisor, until the reset.
const fableWindow = 'seven_day_overage_included';

// What each use in the account register means, in a word.
const useName = (use) => (use.startsWith('worker:') ? `worker ${use.slice(7)}` : { frontdesk: 'front desk', personal: 'you' }[use] || use);

// A guard: a human use of the account that keeps room under the week's stop line (docs/QUEUE.md, The budget).
const guardNames = { frontdesk: 'Front desk', personal: 'You' };
// The ticket sizes, in the order of their pick-up limits on a meter: the biggest stops being taken first.
const sizes = ['L', 'M', 'S'];
// What a guard keeps now, to one decimal: it is often a few per cent.
const keptNow = (kept) => `${(kept * 100).toFixed(1)} % now`;

// A window's kept room and ceiling from its stop line and its guards, as the server reckons them (limits.ps1).
function reckon(w) {
  w.ceiling = Math.max(0, w.stopAt - (w.guards || []).reduce((sum, g) => sum + g.kept, 0));
  w.kept = w.stopAt - w.ceiling;
}

// One usage window as a meter: the fill is the share used, the handle is the stop line (drag it), the hatched part
// right of it is what the workers leave. Left of it lies what each guard keeps now, in the guard's colour; it ends
// at the handle and moves with it. Under the meter each guard has a slider: its share of a whole week. It keeps the
// part of that share for the time left, so its row gives both figures and the slider's track shows the part.
// Above the 5-hour track stand the pick-up limits, a small handle under the letter of each ticket size: from there
// the workers take no new ticket of that size. A run in flight goes on to the stop line. The week has none.
// $inner goes under the meter, above the guards: the Fable week under the week. The Fable week
// has one pick-up limit, its design line (D): from there no new `design` ticket starts, so the Fable runs in flight end
// under the stop line and the advisor goes on.
function windowMeter(account, key, label, w, inner = '') {
  const read = w.used != null;
  const stop = Math.round(w.stopAt * 100);
  const guards = w.guards || [];
  const keeps = guards.map((g) => `;--keep-${esc(g.use)}:${g.kept * 100}%`).join('');
  const rows = guards.map((g) => `<label class="guard ${esc(g.use)}">
      <span class="key"></span><span>${esc(guardNames[g.use] || g.use)}</span>
      <input type="range" min="0" max="50" value="${Math.round(g.share * 100)}" data-guard="${esc(g.use)}" data-account="${esc(account.name)}" data-left="${w.left}" aria-label="${esc(guardNames[g.use] || g.use)}: its share of a whole week" style="--pos:${g.share * 200}%">
      <span class="amount"><b>${percent(g.share)}</b><small>${keptNow(g.kept)}</small></span></label>`).join('');
  const fable = key === fableWindow;
  const order = fable ? ['design'] : sizes;
  const picks = !w.pickUp ? '' : order.map((size) => `<input type="range" class="pick" min="0" max="100" value="${Math.round(w.pickUp[size] * 100)}" data-pick="${size}" data-account="${esc(account.name)}" data-window="${key}" aria-label="${label}: no new ${size} ticket from this share">
      <span class="flag" style="left:var(--pick-${size})">${fable ? 'D' : size}</span>`).join('');
  const limits = !w.pickUp ? '' : order.map((size) => `;--pick-${size}:${w.pickUp[size] * 100}%`).join('');
  const news = !w.pickUp ? '' : fable ? `<span>New design tickets to <b data-figure="design">${percent(w.pickUp.design)}</b></span>`
    : `<span>New tickets: ${sizes.map((size) => `${size} to <b data-figure="${size}">${percent(w.pickUp[size])}</b>`).join(', ')}</span>`;
  const hint = rows ? `<div class="hint">${(w.left * 7).toFixed(1)} of 7 days left: a guard keeps ${percent(w.left)} of its share</div>` : '';
  return `<div class="window" style="--stop:${stop}%${keeps}${limits};--left:${w.left ?? 1}">
    <div class="window-head"><b>${label}</b><span>${read ? `${percent(w.used)} used` : 'no reading yet'}</span>
      <span class="when">${w.resetsAt ? `resets ${clock(w.resetsAt * 1000)}` : ''}</span></div>
    <div class="meter">
      <div class="fill" style="width:${Math.min(100, (w.used || 0) * 100)}%"></div>
      <div class="zones">${guards.map((g) => `<div class="kept ${esc(g.use)}"></div>`).join('')}<div class="off"></div></div>
      ${picks}
      <input type="range" min="0" max="100" value="${stop}" data-stop="${esc(account.name)}" data-window="${key}" aria-label="${label}: the stop line">
    </div>
    <div class="window-foot">${news}<span class="stop">${fable ? 'Fable advisor stops' : 'Workers stop'} at <b>${percent(w.ceiling)}</b></span></div>${inner}${rows ? `<div class="guards">${rows}${hint}</div>` : ''}</div>`;
}

function accountCard(a) {
  const [tone, glyph, label] = accountStates[a.status] || accountStates.ready;
  const words = a.status === 'refused' && outNames[a.out?.kind] ? outNames[a.out.kind] : label;
  // The refusal as the service worded it, and when the workers test the account next: it says what to do.
  // Only a worker that waits for the account tests it: with none, the time of the next test is in the past.
  const test = a.out && a.out.retryAt > state.now
    ? `The workers test the account again at ${clock(a.out.retryAt * 1000)}, and at once after a sign-in.`
    : 'No worker waits for it now. A worker that gets this account tests it at once.';
  const out = a.out ? `<div class="reason">${markdown(a.out.text || '')}<small>${test}</small></div>` : '';
  const name = esc(a.name);
  // Sign in only while the account is signed out: to change the login of an account, remove it and add one.
  const buttons = a.status === 'signedout' ? [`<button class="primary" data-login="${name}">Sign in</button>`] : [];
  if (a.signedIn) buttons.push(`<button data-ping="${name}" title="Starts its 5-hour window now (about 770 tokens)">Ping</button>`);
  const card = `account:${a.name}`;
  return `<article class="card account ${tone}${busyClass(card)}"${busyAttr(card)}>
    <div class="account-head"><strong>${name}</strong>${a.plan ? `<span class="badge">${esc(a.plan)}</span>` : ''}
      <span class="chip ${tone}">${icon(glyph)}${words}</span>${cross('account', a.name, a.name)}</div>
    <div class="meta"><span class="email">${esc(a.signedIn ? a.email || '' : '')}</span>${badges(a.uses.filter((use) => !use.startsWith('worker:')).map(useName))}${out}</div>
    ${windowMeter(a, 'five_hour', '5 hours', a.five_hour)}${windowMeter(a, 'seven_day', 'Week', a.seven_day,
      a[fableWindow] ? windowMeter(a, fableWindow, 'Fable week', a[fableWindow]) : '')}
    <div class="buttons">${buttons.join('')}</div></article>`;
}

// The sign-in in progress: its link, a box for the code the sign-in page shows, its outcome.
function loginBox(login) {
  if (!login) return '';
  const head = `<h3>Signing in: ${esc(login.account)}</h3>`;
  if (login.state === 'starting') return `<div class="card">${head}<div class="text">Starting the sign-in...</div></div>`;
  if (login.state === 'done') return `<div class="card">${head}<div class="text"><b>Signed in.</b> Check the email on its card.</div></div>`;
  if (login.state === 'failed') return `<div class="card">${head}<div class="text">Failed: ${esc(login.message)}</div>
    <div class="buttons"><button class="primary" data-login="${esc(login.account)}">Try again</button></div></div>`;
  return `<div class="card form">${head}
    <ol class="text"><li><a href="${esc(login.url)}" target="_blank" rel="noopener">Open the sign-in page</a> and sign in as this account, not your own.</li>
    <li>Copy the code it shows and paste it here.</li></ol>
    <input id="login-code" placeholder="Code" autocomplete="off" autocapitalize="none">
    <div class="buttons"><button class="primary" data-login-code>Send code</button><button data-login-cancel>Cancel</button></div></div>`;
}

// ---- Details: the info

// What the queue does and what to expect, for someone who does not know it: plain sections, no
// cards. Each value the owner sets is a link to the tab that sets it. Every setting and reading comes from the
// snapshot, never typed into the text, and a change to a queue rule changes this text in the same pass (docs/APP.md,
// Details). Drawn last, from a snapshot that may be older than this code (stored on the device): each field has a fallback,
// and a fault shows a line, not a broken page.
const setting = (text, tab) => `<a class="val" href="#${tab}">${text}</a>`;
const items = (lines) => `<ul>${lines.filter(Boolean).map((line) => `<li>${line}</li>`).join('')}</ul>`;
const section = (title, body) => `<section><h2>${title}</h2>${body}</section>`;

// One account's limits. Each window starts with its reading now, so a line and the usage never read as the same number.
function infoLimits(a) {
  const at = (share) => setting(percent(share), 'accounts');
  const now = (w) => (w.used != null ? `${percent(w.used)} used${w.resetsAt ? `, resets ${clock(w.resetsAt * 1000)}` : ''}. ` : '');
  const five = a.five_hour || {};
  const week = a.seven_day || {};
  const fable = a[fableWindow];
  const guards = (week.guards || []).map((g) => `${esc((guardNames[g.use] || g.use).toLowerCase())} ${at(g.share)}`);
  const design = fable?.pickUp?.design ?? 1;
  const fableNow = !fable || fable.used == null ? ''
    : fable.used >= fable.ceiling ? ' Now past both lines: no design ticket starts, and new runs get no Fable advisor.'
      : fable.used >= design ? ' Now past the design line: no design ticket starts, and new runs still get the Fable advisor.' : '';
  const lines = [
    five.pickUp && `<b>5 hours:</b> ${now(five)}No new L ticket from ${at(five.pickUp.L)}, no new M from ${at(five.pickUp.M)},
      no new S from ${at(five.pickUp.S)}. Workers stop at ${at(five.ceiling)}.`,
    week.stopAt != null && `<b>Week:</b> ${now(week)}${guards.length
      ? `Your stop line is ${at(week.stopAt)}. Below it the workers keep room for people: ${guards.join(' and ')} of a
        whole week, less as the reset comes closer. Now that is ${percent(week.kept)}, so the workers stop at ${percent(week.ceiling)}.`
      : `Workers stop at ${at(week.stopAt)}.`}`,
    fable ? `<b>Fable week:</b> ${now(fable)}Only a Fable run updates this reading. No new design ticket from
        ${at(design)}. No Fable advisor for new runs from ${at(fable.ceiling)}.${fableNow}`
      : '<b>Fable week:</b> no reading yet. The first Fable run gives one.',
  ];
  const who = (a.uses || []).map(useName).join(', ');
  return `<h3>${esc(a.name)}${who ? ` <span class="sub">${esc(who)}</span>` : ''}</h3>${items(lines)}`;
}

// The project's environment in words: its plugins' titles, '' for a plain git repo.
const environment = (s) => inWords((s.plugins || []).map((p) => esc(p.title || p.name)));

function info(s) {
  const blocking = s.questions.filter((q) => q.blocking).length;
  const advisor = s.advisor;
  const working = (s.accounts || []).filter((a) => (a.uses || []).some((u) => u.startsWith('worker:')));
  const plugins = s.plugins || [];
  // What can differ between the PC's projects, for each of them: its plugins.
  const per = s.per || [{ name: '', plugins }];
  return [
    section('In short', `<p>Workers are Claude sessions on this PC that build tickets (GitHub issues) on their own, one at
      a time. Each works in its own copy of the project${plugins.length ? `, with its environment (${environment(s)})` : ''},
      tests its work and opens a pull request
      (PR), which a merger merges into main. You decide what to build; the scripts manage the work. This page shows what they
      do, asks what only you can decide, and holds their limits.</p>`),
    section('What needs you', items([
      `${setting('Questions', 'questions')}: a worker asks only about the product (a rule, a look, what a user sees), never
        about the workflow. A blocking question holds its PR or ticket until you answer (${blocking} now); answer
        the others when you like. Accept default takes the worker's proposal. A new look comes as three
        candidates with a picture of each, the first built in, and you pick.`,
      `${setting('Stuck', 'queue')} runs (Queue): a run that ended with no PR and no question. Nothing retries by itself:
        read the reason, then Retry (${s.stuck.length} now).`,
      `${setting('Accounts', 'accounts')} that are signed out or refuse runs: their workers wait. Sign in, or give the
        workers another account.`,
      'Your phone gets a push for a blocking question, a stuck run, a limit, an account that is out and a merge.',
    ])),
    section('How a ticket goes through', `<ol>
      <li>A ticket with a priority (P0, P1, P2) waits in the ${setting('Queue', 'queue')}. One with no priority is Parked:
        no worker takes it.</li>
      <li>Queue order: the priority, then the bigger ticket (L, M, S), then the older one.</li>
      <li>A free worker takes the answers and rebases of its own PRs first, then its own ticket, then the first queued ticket
        that its account has room for (Limits).</li>
      <li>Two tickets that change the same files (the same area) never run at the same time. A ticket "Blocked by" others
        waits until they close.</li>
      <li>A run ends in a PR, in a question for you, or held at a limit (Limits). The merged PR closes its ticket.</li>
      <li>A merged PR can add new tickets: follow-ups and open questions. A follow-up without a question joins the queue;
        the others wait under Questions.</li>
    </ol>`),
    section('Who builds what', `${items(s.workers.map((w) => {
      const off = (w.takes || []).filter((t) => !t.on).map((t) => t.name);
      return `Worker ${esc(w.id)}${w.project ? ` (${esc(w.project)})` : ''}: ${setting(esc(statusNames[w.status] || w.status), 'workers')}${w.account ? ` on ${esc(w.account)}` : ''}${off.length
        ? `, takes no ${setting(esc(off.join(', ')), 'workers')} tickets` : ''}.`;
    }))}
      <p>Active takes tickets. Paused takes none and keeps its ticket. Disabled takes none, and other workers take its
        ticket. Force (the arrow on Next) gives a free worker its next ticket now, past the limits.</p>
      <p>A worker's ${setting('Config', 'workers')} sets which complexities it takes.${per.length > 1
        ? ` The project on a worker's ${setting('card', 'workers')} moves the worker to another project.` : ''}</p>`),
    section('Complexities', `<p>The complexity of a ticket chooses the model. The size (S, M, L) only says how much usage
      it takes. A ticket with no complexity label is medium.</p>
      <p>Compacts near: when the context of a run reaches this size, Claude Code replaces the older part with a summary.
        A larger size keeps more of the work in view and uses more for each turn.</p>
      <p>${setting('Details', 'details')} (above) sets the model, the effort, the compact size and the advisor of a
        complexity for all workers${per.length > 1 ? ' of its project' : ''}, from the next run. A run in progress or on
        hold keeps its model, its effort and its advisor.</p>
      ${advisor?.complexities?.length ? `<p>A run with an advisor asks it for a second opinion when it decides to; you do
        not see the advice. A run keeps its advisor to its end; past the Fable advisor line (Limits), new runs start
        without the Fable advisor.</p>` : ''}`),
    section('Plugins', per.map((p) => `${per.length > 1 ? `<h3>${esc(p.name)}</h3>` : ''}${(p.plugins || []).length
      ? items(p.plugins.map((x) => `<b>${esc(x.title || x.name)}</b> ${esc(x.version)}: ${esc(x.description)}`))
      : '<p>None: a plain git repo.</p>'}`).join('')),
    section('Limits', `<p>Each account has three usage windows: 5 hours, the week, and the Fable week (Fable alone). The
      workers use all the room you give them and stop at the lines you set (${setting('Accounts', 'accounts')}). A run that
      reaches a stop line ends at its next checkpoint, and the same session goes on when the account has room again; one
      that the plan's own limit cuts off goes on after the reset.</p>
      ${working.length ? working.map(infoLimits).join('') : quiet('No account has a worker.')}`),
    section('In the background', `<p>Three kinds of script run on this PC as Windows tasks with no window. They start
      when you log on and need nothing from you.</p>
      ${items([
        `<b>A worker script</b> for each worker has its plugins make its environment ready${plugins.length ? '' : ' (none here)'}, chooses its next job, starts the run and checks how the run ended. A free worker looks for a job every few minutes, and at once for Force.`,
        '<b>The merger</b> looks at the open PRs every few minutes. It merges each worker PR that GitHub can merge and no question holds, oldest first. A PR that conflicts with main, or that has a comment of yours its run did not read, goes back to its worker.',
        '<b>This page\'s server</b> reads GitHub once a minute and the workers\' files every few seconds, sends the pushes and does what you click. Tailscale puts it on your phone; nothing is open to the internet. With the PC off, the page shows the last state it had, greyed out.',
        'The scripts and this page use no model; only the runs do. Two small exceptions: with no run for a while, a worker reads an account\'s usage with a one-word request, and Ping starts an account\'s 5-hour window.',
        'A change to the queue\'s scripts loads by itself: a worker restarts on the new code between jobs, so a run never changes code halfway.',
      ])}`),
    section('GitHub', `<p>GitHub holds the record of all work: the tickets, the PRs, every question and answer. The scripts
      read what to do from the labels:</p>
      ${items([
        '<b>P0, P1, P2</b>, <b>size</b>, <b>complexity</b> and <b>area</b>: the priority, usage, model and files above.',
        '<b>worker:N</b>: the worker that has the ticket, until its PR merges.',
        '<b>needs-owner</b>: waits on you. <b>answered</b>: you answered, and its worker applies the answer. <b>needs-rebase</b>: the PR conflicts with main, and its worker rebases it.',
        '<b>follow-up</b> and <b>open-question</b>: tickets from a merged PR that wait under Questions.',
      ])}
      <p>Each worker writes as its own GitHub bot where it has one, else as you, and starts each comment with "Worker N:". At each checkpoint a run pushes
        its work to its own branch, so a stop loses little. Any other comment is yours: on a ticket or its PR it overrides
        the ticket, and the run reads it at its next checkpoint, marks it 👀 and replies. An answer on this page goes to
        GitHub as a comment, and the page changes the labels for you. GitHub builds and tests nothing: the run's own tests
        are the check.</p>`),
    section('The tabs', items([
      `${setting('Workers', 'workers')}: what each worker does now and takes next, its status, account${per.length > 1 ? ', project' : ''} and Config. The last tile adds a worker; the cross on a card removes a disabled worker, and its copy of the project stays on the PC.`,
      `${setting('Accounts', 'accounts')}: usage and the limits above; drag a handle to move one. The last tile adds an account and signs it in; the cross on a card removes an account that nothing uses.`,
      `${setting('Questions', 'questions')}: decisions for you, blocking first.`,
      `${setting('Queue', 'queue')}: Up next with why each ticket waits, Stuck, On hold and Parked.`,
      `${setting('History', 'history')}: merged PRs, and each run with its model, time and cost.`,
      `${setting('Details', 'details')}: the settings that are the same for all workers of a project${per.length > 1 ? ', and its colour' : ''}, then this text.`,
    ])),
  ].join('');
}

// ---- The page

// A tab's count, also at 0; red when something there needs the owner.
function count(id, n, hot) {
  $(id).textContent = String(n);
  $(id).classList.toggle('hot', hot);
}

const quiet = (text) => `<div class="quiet">${text}</div>`;

// Every tab shows every project ('') or the one its select names: one choice for all tabs, kept on the device.
const keep = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) { /* private mode */ } };
const kept = (key) => { try { return JSON.parse(localStorage.getItem(key)); } catch (e) { return null; } };
let shownOf = kept('scriptorium-queue') || '';

function render() {
  const s = states[home];
  const questions = all('questions');
  const blocking = questions.filter(({ item }) => item.blocking);
  const open = questions.filter(({ item }) => !item.blocking);
  // The workers side by side, in the order of their numbers.
  const workers = all('workers').sort((a, b) => a.item.id - b.item.id || a.p.localeCompare(b.p));
  const working = workers.filter(({ item }) => item.activity === 'running').length;
  const stuck = all('stuck');
  const loaded = names.every((p) => states[p].github);
  // Workers counts the workers with a run in flight; Accounts the accounts in use that are not out.
  count('count-workers', working, workers.some(({ item }) => item.activity === 'down'));
  count('count-questions', blocking.length || open.length, blocking.length > 0);
  count('count-queue', all('queued').length + stuck.length, stuck.length > 0);
  count('count-accounts', s.accounts.filter((a) => ['ready', 'limit'].includes(a.status) && a.uses.length).length,
    s.accounts.some((a) => ['signedout', 'refused'].includes(a.status) && (a.own || a.uses.length)));
  document.title = (blocking.length ? `(${blocking.length}) ` : '') + 'Scriptorium' + (working ? ` · ${working} working` : '');

  // Every tab has the same select at the same spot: every project, or one. The tab counters stay for every project.
  // Accounts are the PC's, so its select changes nothing there.
  if (!names.includes(shownOf)) shownOf = '';
  const shown = ({ p }) => !shownOf || p === shownOf;
  // All and each project, each with the count of its items in `list` when the tab has one.
  const projectPick = (label, list) => (names.length > 1 ? `<select data-shown${shownOf ? ` class="of" style="--of:${colorOf(shownOf)}"` : ''} aria-label="${label}">${
    [['', 'All'], ...names.map((p) => [p, p])].map(([value, text]) => `<option value="${esc(value)}"${shownOf === value ? ' selected' : ''}>${esc(text)}${
      list ? ` · ${list.filter(({ p }) => !value || p === value).length}` : ''}</option>`).join('')}</select>` : '');
  put($('workers-projects'), projectPick('The project of the workers', workers));
  put($('accounts-projects'), projectPick('The project shown'));
  put($('details-projects'), projectPick('The project of the details'));

  const workersShown = workers.filter(shown);
  const active = workersShown.filter(({ item }) => item.status === 'active').length;
  $('workers-sub').textContent = `${workersShown.filter(({ item }) => item.activity === 'running').length} working · ${active} of ${workersShown.length} active`;
  put($('all-buttons'), `<button data-status="active" data-worker="all">${icon('play')}All active</button>
    <button data-status="paused" data-worker="all">${icon('pause')}Pause all</button>`);
  put($('worker-list'), (drawEach(workersShown, workerCard) || quiet('No worker has reported yet.')) + addTile('worker', 'Add a worker'));
  if ($('config').open) drawConfig();

  put($('questions-projects'), projectPick('The project of the questions', questions));
  const blockingShown = blocking.filter(shown);
  const openShown = open.filter(shown);

  // An answer being typed survives a redraw of its list.
  const typed = {};
  const typedKey = (t) => `${projectOf(t)}|${t.dataset.key}`;
  document.querySelectorAll('#questions textarea').forEach((t) => { typed[typedKey(t)] = t.value; });
  const loading = quiet('Loading from GitHub...');
  $('blocking-title').textContent = `Blocking · ${blockingShown.length}`;
  $('open-title').textContent = `Not blocking · ${openShown.length}`;
  put($('blocking-list'), drawEach(blockingShown, questionCard) || (loaded ? quiet('No question blocks any work.') : loading));
  put($('open-list'), drawEach(openShown, questionCard) || (loaded ? quiet('No open question.') : loading));
  document.querySelectorAll('#questions textarea').forEach((t) => { if (typed[typedKey(t)]) t.value = typed[typedKey(t)]; });

  // The Queue: every project in one list, or one project (its select). A project's own order stays; between the
  // projects the priority decides.
  const rank = ({ item }) => (['P0', 'P1', 'P2'].indexOf(item.priority) + 4) % 4;
  const queued = all('queued');
  put($('queue-projects'), projectPick('The project of the queue', queued));
  const left = names.filter((p) => !shownOf || p === shownOf).map((p) => states[p].left)
    .reduce((sum, l) => ({ count: sum.count + l.count, seconds: sum.seconds + l.seconds, cost: sum.cost + l.cost }), { count: 0, seconds: 0, cost: 0 });
  put($('queue-stats'), left.count ? `<span><b>${left.count}</b> tickets</span>
    ${left.seconds ? `<span><b>≈ ${Math.round(left.seconds / 3600)} h</b> of runs</span>` : ''}
    ${left.cost ? `<span><b>≈ ${dollars(left.cost)}</b></span>` : ''}` : '');
  const stuckShown = stuck.filter(shown);
  const held = all('held').filter(shown);
  const parked = all('parked').filter(shown);
  put($('stuck-list'), stuckShown.length ? `<h2 class="hot">Stuck · ${stuckShown.length}</h2><div class="list stuck">${drawEach(stuckShown, stuckRow)}</div>` : '');
  put($('queue-list'), drawEach(queued.filter(shown).sort((a, b) => rank(a) - rank(b)), ticketRow) || quiet(loaded ? 'Nothing queued.' : 'Loading...'));
  put($('held-list'), held.length ? `<h2>On hold · ${held.length}</h2><div class="list">${drawEach(held, heldRow)}</div>` : '');
  $('parked-title').textContent = `Parked · ${parked.length}`;
  put($('parked-list'), drawEach(parked, ticketRow) || quiet('None.'));

  // The accounts are the PC's: this address's own project gives them.
  const code = $('login-code')?.value || '';
  within(home, () => {
    put($('login-box'), loginBox(s.login));
    put($('account-list'), (s.accounts.map((a) => tagged(home, accountCard(a))).join('') || quiet('No accounts in the settings.')) + addTile('account', 'Add an account'));
  });
  if (code && $('login-code')) $('login-code').value = code;

  const merged = all('merged');
  put($('history-projects'), projectPick('The project of the history', merged));
  put($('merged-list'), drawEach(merged.filter(shown).sort((a, b) => new Date(b.item.mergedAt) - new Date(a.item.mergedAt)), mergedRow) || quiet('None yet.'));
  put($('run-list'), drawEach(all('runs').filter(shown).sort((a, b) => b.item.at - a.item.at), runRow) || quiet('None yet.'));

  $('stamp').textContent = `Updated ${new Date(s.now * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;

  // Details: the settings of each project in its own scope, then the info. Two containers, so a count in the text
  // that changes never redraws a field of the settings.
  let settings;
  try {
    settings = names.filter((p) => !shownOf || p === shownOf).map((p) => within(p, () => tagged(p, settingsBlock()))).join('');
  } catch (e) {
    settings = quiet('The settings could not be drawn from this state. Pull down or reload to fetch a new one.');
  }
  put($('settings-body'), settings);
  // The info is one text for the PC: this address's project gives the common part, every project its own part.
  let text;
  try {
    // With one project chosen, the text is that project's: its plugins, workers, questions and stuck runs.
    const base = shownOf || home;
    const several = names.length > 1 && !shownOf;
    text = within(base, () => info({
      ...states[base], accounts: s.accounts, questions: questions.filter(shown).map(({ item }) => item), stuck: stuck.filter(shown).map(({ item }) => item),
      workers: workersShown.map(({ p, item }) => ({ ...item, project: several ? p : '' })),
      per: names.filter((p) => !shownOf || p === shownOf).map((p) => ({ name: p, plugins: states[p].plugins })),
    }));
  } catch (e) {
    text = quiet('The info could not be drawn from this state. Pull down or reload to fetch a new one.');
  }
  put($('info-body'), text);
}

// Tabs: each hash shows its view. Older links and notifications name a section that a view now holds.
const viewOf = { home: 'workers', needs: 'questions', qa: 'questions', usage: 'accounts', done: 'history', info: 'details' };
function route() {
  const hash = location.hash.slice(1);
  const name = viewOf[hash] || hash;
  const view = $(name)?.classList.contains('view') ? name : 'workers';
  document.querySelectorAll('.view').forEach((v) => { v.hidden = v.id !== view; });
  document.querySelectorAll('#tabs a').forEach((a) => a.classList.toggle('active', a.dataset.tab === view));
}
window.addEventListener('hashchange', route);
route();

// A page at the PC's own address uses each project's address on the PC. A page on a Tailscale device uses the
// Tailscale one, and a project without it cannot show there.
const addressOf = (p) => (location.hostname === '127.0.0.1' ? p?.local : p?.url);
// Where a project's server answers this page: this address for its own project, else the project's own address.
const api = (project, path) => (project && project !== home ? `${addressOf(projects.find((p) => p.name === project))}/` : '') + path;

// The PC's projects, and those of them that have a snapshot to show.
function adopt(list) {
  projects = list;
  names = projects.map((p) => p.name).filter((name) => fresh[name]);
}

// The last state reached, kept on the device: with the PC off the app still opens on it, greyed out under a banner.
const stored = 'scriptorium-state';
const remember = () => keep(stored, { fresh, home, projects, at: Date.now() });
function recall() {
  const last = kept(stored);
  // A state from before the page showed every project: one snapshot.
  if (last?.snapshot) {
    const name = last.snapshot.name || 'project';
    return { fresh: { [name]: last.snapshot }, home: name, projects: [{ name }], at: last.at };
  }
  return last?.fresh ? last : null;
}

function setOffline(offline) {
  document.body.classList.toggle('offline', offline);
  const banner = $('offline');
  banner.hidden = !offline;
  if (offline) {
    const last = recall();
    banner.textContent = `Can't reach your PC${last ? ` since ${clock(last.at)}` : ''}. Is it on, and Tailscale connected?`;
  }
}

// A project that this page cannot load now: its server does not answer (its last state stays on the page), or it has
// no address on this device.
function setNotice(down, away) {
  const lines = [down.length && `Can't reach ${inWords(down)}: ${down.length > 1 ? 'their' : 'its'} last state shows.`,
    away.length && `${inWords(away)} ${away.length > 1 ? 'show' : 'shows'} on the PC only: no Tailscale address.`].filter(Boolean);
  $('notice').hidden = !lines.length;
  $('notice').textContent = lines.join(' ');
}

// Shows the last snapshots with the unconfirmed actions on top. An action goes when a snapshot of its project that
// was fetched after the server's yes confirms it, or when it waited too long.
function draw(animate) {
  const paint = () => {
    states = {};
    for (const p of names) states[p] = structuredClone(fresh[p]);
    for (const op of new Set(ops.values())) {
      const s = states[op.project];
      if (!s || (op.responded && (seen[op.project] || 0) > op.seq && (!op.done || op.done(s) || Date.now() > op.until))) {
        for (const [key, value] of ops) if (value === op) ops.delete(key);
        continue;
      }
      op.apply?.(s);
      if (op.responded) op.after?.(s);
    }
    render();
  };
  // A change the owner made moves smoothly from the old state to the new one; the 10 s refresh does not animate.
  if (animate && document.startViewTransition && !matchMedia('(prefers-reduced-motion: reduce)').matches) document.startViewTransition(paint);
  else paint();
}

async function load(project) {
  const response = await fetch(api(project, 'api/state'), { cache: 'no-store', signal: AbortSignal.timeout(8000) });
  const snapshot = await response.json();
  if (!snapshot.workers) throw new Error('no state');
  return snapshot;
}

// This address's project first: it names the PC's projects. Then every other project from its own address, at the
// same time; one that does not answer keeps its last snapshot.
async function refresh(animate) {
  const fetched = ++fetches;
  let own;
  try {
    own = await load('');
  } catch (e) {
    const last = !names.length && recall();
    if (last) {
      ({ fresh, home } = last);
      adopt(last.projects);
    }
    if (names.length) draw(false);
    setOffline(true);
    return;
  }
  home = own.name || 'project';
  const list = own.projects?.length ? own.projects : [{ name: home }];
  for (const name of Object.keys(fresh)) if (!list.some((p) => p.name === name)) delete fresh[name];
  fresh[home] = own;
  seen[home] = fetched;
  adopt(list);
  setOffline(false);
  draw(animate);
  const others = list.filter((p) => p.name !== home);
  const reach = others.filter(addressOf);
  const results = await Promise.allSettled(reach.map((p) => load(p.name)));
  const down = [];
  results.forEach((result, i) => {
    const { name } = reach[i];
    if (result.status !== 'fulfilled') down.push(name);
    else if (fetched >= (seen[name] || 0)) {
      fresh[name] = result.value;
      seen[name] = fetched;
    }
  });
  adopt(list);
  remember();
  setNotice(down, others.filter((p) => !addressOf(p)).map((p) => p.name));
  if (reach.length) draw(false);
}

function toast(text) {
  const box = $('toast');
  box.textContent = text;
  box.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { box.hidden = true; }, 3500);
}

// Posts an action to a project's server. `keys` are the cards it changes: the change shows at once (apply), and those
// cards stay busy until a snapshot confirms it. A refusal takes the change back and says why.
async function act(project, body, { keys = [], apply, after, done } = {}) {
  const op = { project, apply, after, done, responded: false };
  for (const key of keys) ops.set(`${project}|${key}`, op);
  if (keys.length) draw(true);
  let ok = false;
  try {
    const response = await fetch(api(project, 'api/action'), {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Queue': '1' }, body: JSON.stringify(body),
    });
    const result = await response.json();
    ok = result.ok;
    if (!ok) toast(`Failed: ${result.message}`);
  } catch (e) {
    toast('Cannot reach Scriptorium');
  }
  if (ok) Object.assign(op, { responded: true, seq: fetches, until: Date.now() + 90000 });
  else for (const key of keys) ops.delete(`${project}|${key}`);
  await refresh(true);
  return ok;
}

// Asks before an action, in the page's own dialog, the same for every action: a title, a text, the fields to fill
// (`fields`, HTML; adding something) and the action's button (red for `danger`). Resolves to the fields' values for yes
// (an object, empty without fields), false for Cancel and Escape. Without `yes` it only tells: one Close button.
function ask(title, text, yes, { fields = '', danger = false } = {}) {
  const dialog = $('ask');
  $('ask-title').textContent = title;
  $('ask-text').textContent = text;
  $('ask-fields').innerHTML = fields;
  $('ask-fields').hidden = !fields;
  $('ask-yes').textContent = yes || '';
  $('ask-yes').hidden = !yes;
  $('ask-yes').className = danger ? 'danger' : 'primary';
  $('ask-no').textContent = yes ? 'Cancel' : 'Close';
  dialog.returnValue = '';
  dialog.showModal();
  // A removal never goes on a stray Enter.
  if (danger) $('ask-no').focus();
  return new Promise((resolve) => dialog.addEventListener('close', () => resolve(dialog.returnValue === 'yes'
    && Object.fromEntries(new FormData(dialog.querySelector('form')))), { once: true }));
}

// A list in words: "a", "a and b", "a, b and c".
const inWords = (list) => (list.length > 1 ? `${list.slice(0, -1).join(', ')} and ${list.at(-1)}` : list[0] || '');

// One worker more, on the account the owner picks; the server gives it the lowest number that no worker of the PC has.
async function addWorker() {
  const accounts = states[home].accounts || [];
  const options = accounts.map((a) => `<option value="${esc(a.name)}">${esc(a.name)}${outMark[a.status] || ''}</option>`);
  // The command-line login, offered as on a worker's card: only while no entry is that login.
  if (accounts.every((a) => a.own)) options.unshift('<option value="">command line</option>');
  // The project it works in, while the PC has two or more: the server of that project adds it. The accounts are the
  // PC's, the same for each.
  const pick = names.length > 1
    ? `<label>Project<select name="project">${names.map((p) => `<option${p === home ? ' selected' : ''}>${esc(p)}</option>`).join('')}</select></label>` : '';
  const values = await ask('Add a worker', 'It starts as Active. It takes tickets when its copy of the repo is made and its environment is ready.', 'Add worker', {
    fields: `${pick}<label>Account<select name="account">${options.join('')}</select></label>`,
  });
  if (values) await act(values.project || home, { action: 'add-worker', account: values.account || '' });
}

// One account more: its name and email, then the sign-in on this tab (loginBox).
async function addAccount() {
  const values = await ask('Add an account', 'Then sign in as that account: this tab shows the link and a box for the code.',
    'Add and sign in', {
      fields: `<label>Name<input name="account" required pattern="[a-zA-Z0-9][a-zA-Z0-9\\-]{0,30}" title="Letters, digits and dashes"
          placeholder="e.g. temp1" autocomplete="off" autocapitalize="none"></label>
        <label>Email (optional)<input name="email" type="email" placeholder="Its email" autocomplete="off" autocapitalize="none"></label>`,
    });
  if (!values) return;
  const account = values.account.trim().toLowerCase();
  if (await act(home, { action: 'login', account, email: values.email.trim(), new: true })) $('login-box').scrollIntoView({ block: 'nearest' });
}

// Only a disabled worker with no run goes (its ticket is free then); the dialog says what to do first.
async function removeWorker(project, id) {
  const worker = workerOf(states[project], id);
  if (!worker) return;
  const title = `Remove worker ${id}?`;
  // A disabled worker whose script is gone goes too, though its state still names a run: nothing finishes that run.
  const disabled = worker.status === 'disabled' || (worker.pending?.to === 'disabled' && worker.activity === 'down');
  if (worker.activity === 'setup') {
    await ask(title, 'Its setup still runs. When the setup has ended, remove it.');
  } else if (!disabled && worker.pending?.to === 'disabled') {
    await ask(title, 'It is disabled when its run ends. Then remove it.');
  } else if (!disabled) {
    if (await ask(title, 'Disable it first: its ticket then goes back to the queue. When it shows Disabled, remove it.', 'Disable')) setStatus(project, id, 'disabled');
  } else if (await ask(title, `Its script stops and its card goes. Its copy of the repo stays on the PC: a new worker ${id} uses it again.`,
    'Remove', { danger: true })) {
    await act(project, { action: 'remove-worker', worker: id }, {
      keys: [`worker:${id}`],
      after: (s) => { s.workers = s.workers.filter((w) => w.id !== id); },
      done: (s) => !s.workers.some((w) => w.id === id),
    });
  }
}

// Only an account nothing uses goes: its login is signed out.
async function removeAccount(name) {
  const account = accountOf(states[home], name);
  if (!account) return;
  const title = `Remove ${name}?`;
  if (account.uses.length) {
    const users = account.uses.map((use) => ({ frontdesk: 'the front desk', personal: 'you' }[use] || useName(use)));
    await ask(title, `${inWords(users)} ${users.length > 1 || users[0] === 'you' ? 'use' : 'uses'} it. Move ${users.length > 1 ? 'them' : 'it'} to another account first.`
      .replace(/^./, (c) => c.toUpperCase()));
    return;
  }
  if (!(await ask(title, 'Its login is signed out, and its card goes.', 'Remove', { danger: true }))) return;
  await act(home, { action: 'remove-account', account: name }, {
    keys: [`account:${name}`],
    after: (s) => { s.accounts = s.accounts.filter((a) => a.name !== name); },
    done: (s) => !s.accounts.some((a) => a.name === name),
  });
}

// How a run ends when its worker is paused or disabled: asked only while a run is in flight.
const howOptions = {
  now: ['power', 'Now', 'The run ends at once. Work since its last checkpoint is lost.'],
  checkpoint: ['pause', 'Next checkpoint', 'The run saves its work, then stops.'],
  finish: ['check', 'After the ticket', 'The run finishes its ticket first.'],
};
const keeps = { paused: 'The worker keeps its ticket.', disabled: 'Its ticket goes back to the queue.' };

// Sends a status. Shown at once: the new status, or the target as pending while a run still works toward it.
function sendStatus(project, worker, to, how) {
  const mine = (s) => s.workers.filter((w) => worker === 'all' || w.id === worker);
  return act(project, { action: 'status', worker, to, how }, {
    keys: mine(states[project]).map((w) => `worker:${w.id}`),
    apply: (s) => mine(s).forEach((w) => {
      if (to !== 'active' && w.run && how !== 'now' && w.status === 'active') w.pending = { to, how };
      else Object.assign(w, { status: to, pending: null }, to === 'disabled' ? { next: null } : {});
    }),
  });
}

// "all" is the workers of every project.
// 'all' is every worker of the projects shown (the select).
const statusTo = (project, worker, to, how) => Promise.all((worker === 'all' ? names.filter((p) => !shownOf || p === shownOf) : [project]).map((p) => sendStatus(p, worker, to, how)));

function setStatus(project, worker, to) {
  const views = worker === 'all' ? all('workers').filter(({ p }) => !shownOf || p === shownOf).map(({ item }) => item)
    : states[project].workers.filter((w) => w.id === worker);
  const who = worker === 'all' ? `all workers${shownOf ? ` of ${shownOf}` : ''}` : `worker ${worker}`;
  if (to === 'active' || !views.some((w) => w.run)) {
    statusTo(project, worker, to, to === 'active' ? '' : 'now');
    return;
  }
  $('how').dataset.project = project;
  $('how-title').textContent = `${to === 'paused' ? 'Pause' : 'Disable'} ${who}`;
  $('how-options').innerHTML = Object.entries(howOptions).map(([how, [glyph, name, effect]]) => `<button data-how="${how}" data-to="${to}" data-worker="${esc(worker)}">
    ${icon(glyph)}<span><b>${name}</b><small>${effect}${how === 'finish' ? '' : ` ${keeps[to]}`}</small></span></button>`).join('');
  $('how').showModal();
}

// An answer in text, or no text to take the default; the server decides what the queue does with it. Once the server
// said yes, the question is hidden until GitHub's next fetch drops it, so none is sent twice.
const answer = (project, key, text) => act(project, { action: 'answer', key, text }, {
  keys: [`question:${key}`],
  after: (s) => { s.questions = s.questions.filter((q) => q.key !== key); },
  done: (s) => !s.questions.some((q) => q.key === key),
});

// The advisor of a complexity (Details): its switch and its effort without it, saved as one pick, as the model and
// effort are.
function setAdvisor(project, row, name, on) {
  const fallback = row.querySelector('[data-fallback]').value;
  const same = (c) => c.advisorOn === on && (c.advisorFallback || '') === fallback;
  return act(project, { action: 'advisor', complexity: name, on, fallback }, {
    keys: [`complexity:${name}`],
    apply: (s) => { Object.assign(complexityOf(s, name), { advisorOn: on, advisorFallback: fallback }); },
    done: (s) => same(complexityOf(s, name)),
  });
}

// The project's colour (Details): #rrggbb, or '' for the one from its name.
const setColor = (project, value) => act(project, { action: 'color', value }, {
  keys: ['color'],
  apply: (s) => { s.color = value; },
  done: (s) => (s.color || '') === value,
});

document.addEventListener('click', async (e) => {
  const target = e.target.closest('button');
  if (!target) return;
  const data = target.dataset;
  const project = projectOf(target);
  if (data.status) {
    setStatus(project, data.worker, data.status);
  } else if (data.more) {
    const open = !opened.delete(`${project}|${data.more}`);
    if (open) opened.add(`${project}|${data.more}`);
    target.closest('.worker').classList.toggle('open', open);
    target.setAttribute('aria-expanded', open);
  } else if (data.take) {
    const on = target.getAttribute('aria-pressed') !== 'true';
    await act(project, { action: 'complexity', worker: data.worker, complexity: data.take, on }, {
      keys: [`worker:${data.worker}`],
      apply: (s) => { workerOf(s, data.worker).takes.find((t) => t.name === data.take).on = on; },
    });
  } else if (data.advisor) {
    await setAdvisor(project, target.closest('.config-row'), data.advisor, target.getAttribute('aria-pressed') !== 'true');
  } else if (data.colorReset !== undefined) {
    await setColor(project, '');
  } else if (data.how) {
    $('how').close();
    await statusTo(project, data.worker, data.to, data.how);
  } else if (data.force) {
    const next = workerOf(states[project], data.force)?.next;
    if (next && !next.available && !(await ask(`Take "${next.title}" now?`,
      `The queue holds it back: ${next.why}. The run goes past the stop line and uses the room kept under it.`, 'Take it'))) return;
    await act(project, { action: 'force', worker: data.force }, { keys: [`worker:${data.force}`], apply: (s) => { workerOf(s, data.force).forced = true; } });
  } else if (data.unforce) {
    await act(project, { action: 'unforce', worker: data.unforce }, { keys: [`worker:${data.unforce}`], apply: (s) => { workerOf(s, data.unforce).forced = false; } });
  } else if (data.answer) {
    const text = target.closest('.question').querySelector('textarea').value.trim();
    if (!text) { toast('Write an answer first'); return; }
    await answer(project, data.answer, text);
  } else if (data.default) {
    await answer(project, data.default, '');
  } else if (data.retry) {
    await act(project, { action: 'retry', key: data.retry }, {
      keys: [`stuck:${data.retry}`],
      after: (s) => { s.stuck = s.stuck.filter((item) => item.key !== data.retry); },
      done: (s) => !s.stuck.some((item) => item.key === data.retry),
    });
  } else if (data.login) {
    await act(home, { action: 'login', account: data.login }, { keys: [`account:${data.login}`] });
  } else if (data.loginCode !== undefined) {
    const code = $('login-code').value.trim();
    if (!code) { toast('Paste the code first'); return; }
    target.disabled = true;
    if (await act(home, { action: 'login-code', code })) $('login-code').value = '';
  } else if (data.loginCancel !== undefined) {
    if (await ask('Cancel the sign-in?', 'The account stays as it is.', 'Cancel the sign-in')) await act(home, { action: 'login-cancel' });
  } else if (data.ping) {
    await act(home, { action: 'ping', account: data.ping }, { keys: [`account:${data.ping}`] });
  } else if (data.add) {
    await (data.add === 'worker' ? addWorker() : addAccount());
  } else if (data.remove) {
    await (data.remove === 'worker' ? removeWorker(project, data.name) : removeAccount(data.name));
  } else if (data.config) {
    configOf = { project, id: data.config };
    $('config').dataset.project = project;
    drawConfig();
    $('config').showModal();
  } else if (data.steps) {
    $('steps-title').textContent = `Worker ${data.steps}${names.length > 1 ? ` on ${project}` : ''}: latest run`;
    $('steps-list').innerHTML = '<li>Loading...</li>';
    $('steps').showModal();
    try {
      const log = await (await fetch(api(project, `api/log?worker=${encodeURIComponent(data.steps)}`), { cache: 'no-store' })).json();
      $('steps-list').innerHTML = (log.steps || []).map((s) => `<li>${esc(s)}</li>`).join('') || '<li>No run yet.</li>';
    } catch (err) {
      $('steps-list').innerHTML = '<li>Cannot reach Scriptorium.</li>';
    }
  } else if (data.close !== undefined) {
    target.closest('dialog').close();
  }
});

// A stop line, a pick-up limit or a guard follows its handle while it moves; letting go saves it.
document.addEventListener('input', (e) => {
  const data = e.target.dataset;
  if (!data.stop && !data.guard && !data.pick) return;
  const box = e.target.closest('.window');
  if (data.pick) {
    box.style.setProperty(`--pick-${data.pick}`, `${e.target.value}%`);
    box.querySelector(`[data-figure="${data.pick}"]`).textContent = percent(e.target.value / 100);
    return;
  }
  if (data.stop) {
    if (e.target.value < 10) e.target.value = 10;
    box.style.setProperty('--stop', `${e.target.value}%`);
  } else {
    box.style.setProperty(`--keep-${data.guard}`, `${e.target.value * data.left}%`);
    e.target.style.setProperty('--pos', `${e.target.value * 2}%`);
    const amount = e.target.nextElementSibling;
    amount.firstElementChild.textContent = percent(e.target.value / 100);
    amount.lastElementChild.textContent = keptNow(e.target.value / 100 * data.left);
  }
  const stop = box.querySelector('[data-stop]').value / 100;
  const kept = [...box.querySelectorAll('[data-guard]')].reduce((sum, g) => sum + g.value / 100 * g.dataset.left, 0);
  box.querySelector('.window-foot .stop b').textContent = percent(Math.max(0, stop - kept));
});

// A slider in the hand stands out (style.css, .held). On a touch screen a slider moves only after a short hold on its
// handle, so a scroll across the page never moves one: there the sliders take no pointer (style.css), the hold arms
// the nearest handle, and it then follows the finger from where it stands. Letting go saves it.
const holdMs = 300;
let hold = null;
// The nearest handle of an account's sliders to a point, if one is in reach of a finger.
function handleAt(box, x, y) {
  let best = null;
  for (const input of box.querySelectorAll('input[type=range]')) {
    const rect = input.getBoundingClientRect();
    const thumb = input.dataset.pick ? 22 : 18;
    const travel = rect.width - thumb;
    const middle = rect.left + thumb / 2 + (input.value - input.min) / (input.max - input.min) * travel;
    const distance = Math.hypot(x - middle, y - rect.top - rect.height / 2);
    if (distance < 28 && (!best || distance < best.distance)) best = { input, distance, travel };
  }
  return best;
}
function release() {
  if (!hold) return;
  clearTimeout(hold.timer);
  const { input, from, armed } = hold;
  hold = null;
  if (!armed) return;
  input.classList.remove('held');
  if (Number(input.value) !== from) input.dispatchEvent(new Event('change', { bubbles: true }));
  else input.blur();
}
document.addEventListener('pointerdown', (e) => {
  if (!matchMedia('(pointer: coarse)').matches) {
    if (e.target.matches?.('.window input[type=range]')) e.target.classList.add('held');
    return;
  }
  // The whole card: a handle at the end of its track lies half outside its window.
  const box = e.target.closest?.('.account');
  const hit = !hold && box && handleAt(box, e.clientX, e.clientY);
  if (!hit) return;
  hold = { ...hit, id: e.pointerId, x: e.clientX, y: e.clientY, from: Number(hit.input.value), armed: false };
  hold.timer = setTimeout(() => {
    if (!hold.input.isConnected) return release();
    hold.armed = true;
    hold.input.classList.add('held');
    // The focus keeps the 10 s refresh from a redraw under the finger (put).
    hold.input.focus({ preventScroll: true });
    navigator.vibrate?.(10);
  }, holdMs);
});
document.addEventListener('pointermove', (e) => {
  if (!hold || e.pointerId !== hold.id) return;
  if (!hold.armed) {
    // The finger moved before the hold was over: it is a scroll.
    if (Math.hypot(e.clientX - hold.x, e.clientY - hold.y) > 8) release();
    return;
  }
  const { input } = hold;
  const moved = (e.clientX - hold.x) / hold.travel * (input.max - input.min);
  const value = Math.round(Math.min(input.max, Math.max(input.min, hold.from + moved)));
  if (value === Number(input.value)) return;
  input.value = value;
  input.dispatchEvent(new Event('input', { bubbles: true }));
});
for (const type of ['pointerup', 'pointercancel']) {
  document.addEventListener(type, (e) => {
    document.querySelector('input.held')?.classList.remove('held');
    if (hold && e.pointerId === hold.id) release();
  });
}
// Pull down to refresh, as in a phone app: with the list at its top, a drag down brings a mark from the top edge, and
// letting go past the line loads the page again (new code and a fresh state). The page itself never scrolls (its
// panes do), so the browser's own pull to refresh cannot work here.
const pullMark = $('pull');
const pullLine = 110;
let pull = null;
function endPull(e) {
  const go = pull && pull.by >= pullLine && e?.type === 'touchend';
  pull = null;
  pullMark.classList.add('back');
  pullMark.classList.toggle('go', Boolean(go));
  if (go) {
    location.reload();
    return;
  }
  pullMark.classList.remove('ready');
  pullMark.style.setProperty('--pull', '0px');
}
document.addEventListener('touchstart', (e) => {
  pull = null;
  if (e.touches.length !== 1 || e.target.closest('dialog, .pop')) return;
  // Only from the top: no list under the finger is scrolled down.
  for (let el = e.target; el; el = el.parentElement) if (el.scrollTop > 0) return;
  pull = { x: e.touches[0].clientX, y: e.touches[0].clientY, by: 0 };
}, { passive: true });
document.addEventListener('touchmove', (e) => {
  if (!pull) return;
  const dx = e.touches[0].clientX - pull.x;
  const dy = e.touches[0].clientY - pull.y;
  // A slider in the hand, a second finger, or a drag up or to the side: not a pull.
  if (hold?.armed || e.touches.length !== 1 || dy < 0 || (!pull.by && Math.abs(dx) > Math.abs(dy))) {
    endPull();
    return;
  }
  pull.by = dy;
  pullMark.classList.remove('back');
  pullMark.classList.toggle('ready', dy >= pullLine);
  pullMark.style.setProperty('--pull', `${Math.min(dy, 170) * 0.55}px`);
  pullMark.style.setProperty('--turn', `${dy * 2}deg`);
}, { passive: true });
document.addEventListener('touchend', endPull);
document.addEventListener('touchcancel', endPull);

// An armed slider holds the page still, and a long hold opens no menu.
document.addEventListener('touchmove', (e) => { if (hold?.armed) e.preventDefault(); }, { passive: false });
document.addEventListener('contextmenu', (e) => { if (hold) e.preventDefault(); });

document.addEventListener('change', async (e) => {
  const data = e.target.dataset;
  const project = projectOf(e.target);
  if (data.shown !== undefined) {
    shownOf = e.target.value;
    keep('scriptorium-queue', shownOf);
    e.target.blur();
    draw(false);
  } else if (data.assign) {
    e.target.blur();
    const account = e.target.value;
    await act(project, { action: 'assign', worker: data.assign, account }, { keys: [`worker:${data.assign}`], apply: (s) => { workerOf(s, data.assign).account = account; } });
  } else if (data.move) {
    // The card shows the worker's own project until the move is done: the next snapshots show it in the new one.
    const target = e.target.value;
    e.target.value = project;
    e.target.blur();
    const text = `It keeps its number, its account, its status and its complexities. Its copy of ${target} is made at its first move there. `
      + `Its copy of ${project} stays on the PC, and the other workers of ${project} take its open PRs.`;
    if (await ask(`Move worker ${data.move} to ${target}?`, text, 'Move')) {
      await act(target, { action: 'move-worker', worker: data.move, from: project });
    }
  } else if (data.priority) {
    e.target.blur();
    // GitHub holds the priority: the row stays busy until the next fetch shows it.
    const number = Number(data.priority);
    const priority = e.target.value;
    await act(project, { action: 'priority', number, priority }, {
      keys: [`ticket:${number}`],
      apply: (s) => { const row = rowOf(s, number); if (row) row.priority = priority === 'park' ? '' : priority; },
      done: (s) => (rowOf(s, number)?.priority || 'park') === priority,
    });
  } else if (data.stop) {
    e.target.blur();
    const value = e.target.value / 100;
    await act(home, { action: 'stop-at', account: data.stop, window: data.window, value }, {
      keys: [`account:${data.stop}`],
      apply: (s) => {
        // The room the guards keep stays under the line, wherever the line goes.
        const w = accountOf(s, data.stop)[data.window];
        w.stopAt = value;
        reckon(w);
      },
    });
  } else if (data.pick) {
    e.target.blur();
    const value = e.target.value / 100;
    await act(home, { action: 'pick-up', account: data.account, window: data.window, size: data.pick, value }, {
      keys: [`account:${data.account}`],
      apply: (s) => { accountOf(s, data.account)[data.window].pickUp[data.pick] = value; },
    });
  } else if (data.compact) {
    // The compact size of a complexity (Details): typed in thousands of tokens, saved in tokens.
    e.target.blur();
    const name = data.compact;
    const value = Math.round(Number(e.target.value));
    if (!(value >= e.target.min && value <= e.target.max)) {
      toast(`Between ${e.target.min}k and ${e.target.max}k tokens`);
      e.target.value = Math.round(complexityOf(states[project], name).compactAt / 1000);
      return;
    }
    await act(project, { action: 'compact-at', complexity: name, value: value * 1000 }, {
      keys: [`complexity:${name}`],
      apply: (s) => { complexityOf(s, name).compactAt = value * 1000; },
      done: (s) => complexityOf(s, name).compactAt === value * 1000,
    });
  } else if (data.runModel || data.runEffort) {
    // The model and effort of a complexity (Details): the two lists of its row, saved as one pick.
    e.target.blur();
    const name = data.runModel || data.runEffort;
    const row = e.target.closest('.config-row');
    const pick = { model: row.querySelector('[data-run-model]').value, effort: row.querySelector('[data-run-effort]').value };
    const same = (a) => a.model === pick.model && a.effort === pick.effort;
    await act(project, { action: 'model', complexity: name, ...pick }, {
      keys: [`complexity:${name}`],
      apply: (s) => { Object.assign(complexityOf(s, name), pick); },
      done: (s) => same(complexityOf(s, name)),
    });
  } else if (data.fallback) {
    e.target.blur();
    const c = complexityOf(states[project], data.fallback);
    await setAdvisor(project, e.target.closest('.config-row'), data.fallback, c.advisorOn ?? Boolean(c.advisor));
  } else if (data.advisorModel !== undefined) {
    // The advisor's model of the project (Details).
    e.target.blur();
    const model = e.target.value;
    await act(project, { action: 'advisor-model', model }, {
      keys: ['advisor-model'],
      apply: (s) => { s.advisor = { ...s.advisor, model }; },
      done: (s) => s.advisor?.model === model,
    });
  } else if (data.color) {
    e.target.blur();
    const value = e.target.value.toLowerCase();
    if (/^#[0-9a-f]{6}$/.test(value)) await setColor(project, value);
  } else if (data.guard) {
    e.target.blur();
    const value = e.target.value / 100;
    await act(home, { action: 'keep', use: data.guard, value }, {
      keys: [`account:${data.account}`],
      apply: (s) => {
        // The use keeps its share on whatever account it is on.
        for (const a of s.accounts) {
          const w = a.seven_day;
          const guard = (w.guards || []).find((g) => g.use === data.guard);
          if (!guard) continue;
          Object.assign(guard, { share: value, kept: value * w.left });
          reckon(w);
        }
      },
    });
  }
});

document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
setInterval(() => { if (!document.hidden) refresh(); }, 10000);
try {
  localStorage.removeItem('scriptorium-project');
  localStorage.removeItem('scriptorium-projects');
} catch (e) { /* private mode */ }
if (location.search) history.replaceState(null, '', location.pathname + location.hash);
const last = recall();
if (last) {
  ({ fresh, home } = last);
  adopt(last.projects);
  if (names.length) draw(false);
}
refresh();
// The tab icon is the mark alone, in the ink that shows on the browser's own colour. The link starts as the tile
// (index.html), so a browser that keeps its first icon still shows one.
const darkScheme = matchMedia('(prefers-color-scheme: dark)');
const setTabIcon = () => { document.querySelector('link[rel="icon"]').href = darkScheme.matches ? 'mark-on-dark.png' : 'mark-on-light.png'; };
darkScheme.addEventListener('change', setTabIcon);
setTabIcon();
if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
