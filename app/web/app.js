// The queue app's page (docs/APP.md): renders every project's /api/state every 5 s while visible, posts the owner's
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
// A worker's complexity: its switch and the row of its mapping (the snapshot's `takes`).
const takeOf = (s, worker, name) => workerOf(s, worker)?.takes?.find((t) => t.name === name);
const rowOf = (s, number) => [...s.queued, ...s.parked].find((row) => row.number === number);

// Redraws a list only when it changed and holds no field in use, so typing, the phone keyboard and open folds
// survive the 5 s refresh.
const drawn = new WeakMap();
// A card being moved (Reorder, below): its list waits for the drop.
let drag = null;
function put(el, html) {
  const active = document.activeElement;
  if (el.contains(active) && active.matches('textarea, select, input')) return;
  if (drag && el.contains(drag.card)) return;
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

// A model's name on the page: the one the provider's models.json gives it (`title`), else its id.
function modelName(id) {
  return state.modelTitles?.[id] || id || '';
}

// Questions and tickets arrive as markdown: links, bold, code, italics and line breaks are enough to read them. A link
// into the repo has no address the page can open, so it shows as its text. A bare address is a link too; a GitHub
// issue or PR address shows as repo#N, as GitHub shows it. A question's picture on its shots branch (shots.ps1)
// shows as the picture, from the server (the repo is private); a tap opens it in the viewer.
const shotRe = /!\[([^\]]*)\]\(https:\/\/github\.com\/[^/\s]+\/[^/\s]+\/blob\/(shots-t\d+)\/([\w.-]+\.(?:png|jpe?g))(?:\?raw=true)?\)/i;
const shotHtml = (all, alt, branch, name) => {
  const src = `${api(scope, 'api/shot')}?branch=${branch}&amp;name=${name}`;
  return `<a class="shot" href="${src}" target="_blank"><img src="${src}" alt="${alt}" loading="lazy"></a>`;
};
// One choice of a question: its picture beside its text. One without a picture is a row of text.
function choice(line) {
  const shot = shotRe.exec(line);
  // The choice's name, up to its first colon, stands bold on a line of its own above what it changes.
  const text = inline(line.replace(/^\s*[-*] /, '').replace(shotRe, '').trim().replace(/:$/, '')).replace(/^([^:<]{1,60}):\s+/, '<b>$1</b><br>');
  return `<div class="choice">${shot ? shotHtml(...shot) : ''}<div>${text}</div></div>`;
}
// The page arranges the pictures, not the writer: list lines that stand together and hold a picture are the choices,
// one row each, the same for every count of pictures (PLAYBOOK-pictures.md).
function markdown(text) {
  const parts = [];
  let run = [];
  const flush = () => {
    if (!run.length) return;
    parts.push(run.some((line) => shotRe.test(line))
      ? { html: `<div class="choices">${run.map(choice).join('')}</div>`, block: true } : { html: run.map(inline).join('<br>') });
    run = [];
  };
  // A writer's own wrap of a long line (the next line is indented and starts no list item or picture) is no line
  // break: the page wraps the text.
  for (const line of esc(text).replace(/(\S)[ \t]*\r?\n[ \t]+(?![-*] |\d+\. |!\[)(?=\S)/g, '$1 ').split('\n')) {
    if (/^\s*[-*] /.test(line)) run.push(line);
    else { flush(); parts.push({ html: inline(line) }); }
  }
  flush();
  return parts.map((part, i) => part.html + (parts[i + 1] && !part.block && !parts[i + 1].block ? '<br>' : '')).join('');
}
// A question's banner: its first picture that stands alone on a line, in the question or else in its details. Returns
// the picture and both texts without that line and the empty lines after it; no banner for a question written before
// the rule.
function takeBanner(q) {
  const alone = new RegExp(`^[ \\t]*${shotRe.source}(?:[ \\t]*\\r?\\n)*`, 'im');
  for (const field of ['question', 'details']) {
    const hit = alone.exec(q[field] || '');
    if (hit) return { ...q, [field]: q[field].replace(alone, ''), banner: shotHtml(...esc(hit[0]).match(shotRe)).replace('class="shot"', 'class="shot banner"') };
  }
  return q;
}
function inline(text) {
  return text
    .replace(new RegExp(shotRe.source, 'gi'), shotHtml)
    // An address after a raw " is inside a picture's markup above (esc leaves no other "): not a link again.
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)|(?<!")(https:\/\/[^\s<"]*[^\s<".,;:!?)\]])/g, (all, label, href, bare) => {
      if (bare) {
        const issue = /^https:\/\/github\.com\/[^/]+\/([^/]+)\/(?:pull|issues)\/(\d+)$/.exec(bare);
        return `<a href="${bare}" target="_blank">${issue ? `${issue[1]}#${issue[2]}` : bare}</a>`;
      }
      return /^https:\/\//.test(href) ? `<a href="${href}" target="_blank">${label}</a>` : label;
    })
    .replace(/\*\*(.+?)\*\*/g, '<b>$1</b>')
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<i>$2</i>');
}

// A coding tool's name, from its provider plugin's title without the start every plugin's title has
// (docs/PLUGINS.md, A provider): "Scriptorium for Claude Code" is Claude Code.
const toolTitle = (title) => (title || '').replace(/^Scriptorium for /, '');
// A project's default coding tool, whose models scriptorium.json names. '' with no provider.
const toolOf = (s) => toolTitle(s?.provider);
// Whether a coding tool's provider has each of these hooks (the snapshot's `hooks`). A snapshot from before that list
// (the last state on the device) counts as having them all, as the page showed it then.
const has = (s, ...hooks) => !s?.hooks || hooks.every((hook) => s.hooks.includes(hook));
// The coding tool of a worker or an account, by its provider plugin's name (the snapshot's `tools`): its title, its
// hooks and its usage windows. A worker runs on its account's tool, so one project has workers of several. A snapshot
// from before `tools` has the project's one tool.
const toolView = (s, name) => s?.tools?.[name] || (s?.provider ? { title: s.provider, hooks: s.hooks, windows: s.windows } : null);
const toolName = (s, name) => toolTitle(toolView(s, name)?.title);
// Draws with a coding tool's title, hooks and windows as the state's: an account's card is of the account's tool,
// not of the project's default.
function withTool(name, draw) {
  const before = state;
  const tool = toolView(state, name);
  if (tool) state = { ...state, provider: tool.title, hooks: tool.hooks, windows: tool.windows };
  try {
    return draw();
  } finally {
    state = before;
  }
}
// The coding tools of the PC, each once: every project's default and every tool its page serves.
const toolsOfPc = () => [...new Set(names.flatMap((p) => [states[p]?.provider, ...Object.values(states[p]?.tools || {}).map((t) => t.title)])
  .map(toolTitle).filter(Boolean))];
// What a project's default coding tool has of what a mapping sets, from its models.json: efforts, an advisor, a
// compact size. A snapshot from before `compactRange` counts as having one.
const toolHas = (s) => ({ efforts: (s?.efforts || []).length > 0, advisor: Boolean(s?.advisor?.model || s?.advisor?.base),
  compact: !s?.compactRange || s.compactRange.length === 2 });
// The same of one coding tool (toolView), for a worker's mapping. A snapshot from before a tool had these lists has
// none of the three: its rows show the model alone.
const mappingHas = (tool) => ({ efforts: (tool?.efforts || []).length > 0, advisor: Boolean(tool?.advisor), compact: tool?.compactRange?.length === 2 });
// The efforts one model of a coding tool takes: its own list where its models.json gives one (`perModel`), else the tool's.
const effortsOf = (tool, model) => tool?.perModel?.[model]?.efforts || tool?.efforts || [];
const toolBadge = (tool) => (tool ? `<span class="badge tool" title="The coding tool that runs here">${esc(tool)}</span>` : '');
// The accounts as the options of a select, each by its name alone, so the closed select shows the name. While the PC
// has more than one coding tool, the list is in groups, one for each tool. `tool` gives an account's tool by name.
function accountOptions(accounts, tool, selected) {
  const option = (a) => `<option value="${esc(a.name)}"${a.name === selected ? ' selected' : ''}>${esc(a.name)}${outMark[a.status] || ''}</option>`;
  if (toolsOfPc().length < 2) return accounts.map(option).join('');
  return [...new Set(accounts.map(tool))].map((name) => `<optgroup label="${esc(name)}">${accounts.filter((a) => tool(a) === name).map(option).join('')}</optgroup>`).join('');
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
  // A plugin's hook threw, or a plugin is not installed yet (the text is in Now); the worker tries again at its next look.
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

// A name the owner can change in place (rename): a double-click on it, or Enter while it has focus.
const renameable = (kind, id, name, shown) => `<span class="name" tabindex="0" data-rename="${kind}" data-id="${esc(id)}" data-name="${esc(name || '')}"
  title="Double-click to rename">${esc(name || shown)}</span>`;

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

  // Force moves the next ticket into the free slot now, also one the queue would not give it. Now (the Queue tab)
  // also waits for a run in progress: that run ends at its next checkpoint.
  const next = worker.next;
  const waits = worker.forced && (!worker.run || (worker.now && worker.now !== worker.ticket));
  let force = '';
  if (waits) force = `<button data-unforce="${id}">Cancel</button>`;
  else if (next) {
    const can = worker.status === 'active' && !worker.run && !['down', 'signedout', 'setup', 'setup-failed', 'error'].includes(worker.activity);
    force = `<button class="round" data-force="${id}" title="${can ? 'Take it now' : 'Its slot is not free'}" aria-label="Take it now"${can ? '' : ' disabled'}>${icon('up')}</button>`;
  }
  const kind = next && { answered: 'your answers', 'needs-rebase': 'a rebase', now: 'now' }[next.kind];
  const nextBody = next
    ? `<a class="title${next.available ? '' : ' off'}" href="${esc(next.url)}" target="_blank">${esc(next.title)}</a>
       <div class="meta">${badges([kind, ...(next.areas || []), next.size, next.complexity])}${waits ? `<span class="why">takes it at its next ${worker.run ? 'checkpoint' : 'poll'}</span>`
    : next.available ? '' : `<span class="why">${icon('lock')}${esc(next.why)}</span>`}</div>`
    : `<span class="free">${worker.status === 'disabled' ? 'None' : 'Nothing queued'}</span>`;

  const seg = Object.keys(statusNames).map((s) => `<button data-status="${s}" data-worker="${id}" aria-pressed="${worker.status === s}"
    class="${worker.status === s ? 'on' : ''}${worker.pending?.to === s ? ' pending' : ''}"${worker.status === s ? ` style="view-transition-name:seg-${esc(scope)}-${id}"` : ''}>${icon(statusIcons[s])}<span>${statusNames[s]}</span></button>`).join('');
  const pending = worker.pending ? `<div class="pending-note">${pendingVerbs[worker.pending.to]} ${howNames[worker.pending.how]}</div>` : '';

  // Config opens the worker's config (drawConfig). Its button counts the complexities the worker takes while one is off.
  const all = worker.takes || [];
  const on = all.filter((t) => t.on).length;
  const config = `<button class="config-open" data-config="${id}" aria-label="Config of worker ${id}">${icon('config')}Config${on < all.length ? ` <small>${on}/${all.length}</small>` : ''}</button>`;

  // Its account, of any coding tool: the worker runs on its account's tool, so an account of another tool changes
  // the worker's tool. The accounts stand under their tools while the PC has more than one (accountOptions).
  const accounts = state.accounts || [];
  // A worker in no entry runs on the command-line login; offered only while no entry is that login.
  const options = (!worker.account || accounts.every((a) => a.own) ? `<option value=""${worker.account ? '' : ' selected'}>command line</option>` : '')
    + accountOptions(accounts, (a) => toolName(state, a.provider), worker.account);

  // Its project, while the PC has two or more: the mark is a choice that moves it to another project (`data.move`).
  const fixed = worker.run || worker.ticket ? 'It has a ticket: disable it first, then move it'
    : worker.activity === 'setup' ? 'Its setup still runs' : '';
  const project = names.length > 1
    ? `<select class="badge of" style="--of:${colorOf(scope)}" data-move="${id}" aria-label="Project of worker ${id}"${fixed ? ` disabled title="${fixed}"` : ''}>${
      names.map((p) => `<option${p === scope ? ' selected' : ''}>${esc(p)}</option>`).join('')}</select>` : '';

  const card = `worker:${worker.id}`;
  return `<article class="card worker ${esc(worker.status)}${open ? ' open' : ''}${busyClass(card)}" data-card="${esc(`${scope}|${worker.id}`)}"${busyAttr(card)}>
    <div class="worker-head"><div class="who"><strong>${renameable('worker', id, worker.name, `Worker ${id}`)}${project}</strong>
      <div class="who-line"><span class="doing ${tone}">${icon(glyph)}${words}</span>${toolBadge(toolName(state, worker.provider))}</div></div>
      <button class="round more" data-more="${id}" aria-expanded="${open}" aria-label="Details of worker ${id}">${icon('down')}</button>${cross('worker', id, `worker ${id}`)}</div>
    <div class="status"><div class="seg" role="group" aria-label="Status of worker ${id}">${seg}</div>${pending}</div>
    <div class="worker-tools"><label>${icon('accounts')}<select data-assign="${id}" aria-label="Account of worker ${id}">${options}</select></label>
      ${config}<button data-steps="${id}">${icon('steps')}Steps</button></div>
    <div class="slot now"><span class="slot-label">Now</span><div class="slot-body">${now}</div></div>
    <div class="slot next"><span class="slot-label">Next</span><div class="slot-body">${nextBody}</div>${force}</div></article>`;
}

// A worker's config, the dialog its Config button opens (docs/APP.md, Workers, Config): its mapping (docs/QUEUE.md, A
// worker's mapping) and a switch for each complexity (`workers.<id>.complexity`). Off, the worker takes no new ticket
// of the complexity and leaves the answers and rebases of its PRs of it (`jobs`) until it is on again.
// The mapping is the worker's own, for the coding tool it is on, or another worker's that it follows: a row for each
// complexity with its model and effort, its compact size, its advisor switch and its effort without the advisor. The
// lists are the tool's models.json's (toolView), with the value in use always among them: a list without it would
// show its first entry. The models have the base's own too (`base`, which a project may name outside the list), so
// the way back is always there. A pick that is not the base's shows the base's under it. A row that the worker
// follows is not a field. Each field has a fallback for an older snapshot.
const pickList = (list, value, label) => [...new Set([...list, value])].filter(Boolean)
  .map((v) => `<option value="${esc(v)}"${v === value ? ' selected' : ''}>${esc(label(v))}</option>`).join('');
// At most 17 letters: a phone cuts a longer entry in its list (168 px wide at 375 px).
const fallbackName = (effort) => `${effort || 'same'} without it`;
const workerLabel = (w) => w.name || `Worker ${w.id}`;
// Every worker of the PC, each with its project: a mapping can follow a worker of another project.
const pcWorkers = () => names.flatMap((p) => (states[p]?.workers || []).map((w) => ({ ...w, of: p })));

let configOf = null;
function drawConfig() {
  const worker = configOf && states[configOf.project] && workerOf(states[configOf.project], configOf.id);
  if (!worker) { $('config').close(); return; }
  within(configOf.project, () => drawConfigOf(worker));
}

function mappingRow(worker, t, tool, has) {
  const id = esc(worker.id);
  const name = esc(t.name);
  const key = `mapping:${worker.id}:${t.name}`;
  const locked = t.linked ? ' disabled' : '';
  const on = t.advisorOn ?? Boolean(t.advisor);
  const fallback = t.advisorFallback || '';
  const notes = [t.base && (t.base.model !== t.model || (has.efforts && t.base.effort !== t.effort))
    && `Default: ${esc(modelName(t.base.model))}${has.efforts ? ` · ${esc(t.base.effort)}` : ''}`,
  has.advisor && t.baseAdvisor != null && (t.baseAdvisor !== on || (t.baseFallback || '') !== fallback)
    && `Default: ${t.baseAdvisor ? `advisor, ${esc(fallbackName(t.baseFallback))}` : 'no advisor'}`].filter(Boolean);
  // Only what the coding tool has (mappingHas): with no efforts or no compact size the field keeps its place, unseen;
  // with no advisor the row has none.
  const advisor = !has.advisor || t.model === worker.mapping?.advisor ? ''
    : `<button class="take${on ? ' on' : ''}" data-advisor="${name}" data-worker="${id}" aria-pressed="${on}" aria-label="Advisor of a ${name} run"${locked}>${icon(on ? 'check' : 'lock')}<span><b>Advisor</b></span></button>
      <select data-fallback="${name}" data-worker="${id}" aria-label="Effort of a ${name} run without the advisor"${on && !t.linked ? '' : ' disabled'}>${
  ['', ...(tool?.efforts || [])].map((e) => `<option value="${esc(e)}"${e === fallback ? ' selected' : ''}>${esc(fallbackName(e))}</option>`).join('')}</select>`;
  const [least, most] = has.compact ? tool.compactRange : [0, 0];
  const jobs = !t.on && t.jobs ? `<small>holds ${t.jobs} PR job${t.jobs === 1 ? '' : 's'}</small>` : '';
  // The description is behind an (i) button: a popover that a tap outside closes, so a phone keeps the row short.
  const about = esc(`about-${scope}-${worker.id}-${t.name}`);
  return `<div class="config-row${t.linked ? ' linked' : ''}${busyClass(key)}"${busyAttr(key)}>
    <span class="config-name switch"><button class="take${t.on ? ' on' : ''}" data-take="${name}" data-worker="${id}" aria-pressed="${t.on}" title="${t.on ? 'It takes' : 'It takes no'} ${name} tickets">
      ${icon(t.on ? 'check' : 'lock')}<span><b>${name}</b>${jobs}</span></button>${t.description ? `<button class="about" popovertarget="${about}" aria-label="What ${name} is">${icon('info')}</button>
      <span class="pop about-text" id="${about}" popover>${esc(t.description)}</span>` : ''}</span>
    <select data-run-model="${name}" data-worker="${id}" aria-label="Model of a ${name} run"${locked}>${pickList([...(tool?.models || []), t.base?.model], t.model, modelName)}</select>
    <select data-run-effort="${name}" data-worker="${id}" aria-label="Effort of a ${name} run"${has.efforts ? locked : ' class="none" disabled'}>${pickList(effortsOf(tool, t.model), t.effort, (v) => v)}</select>
    <label class="compact${has.compact ? '' : ' none'}"><input type="number"${has.compact && !t.linked ? '' : ' disabled'} inputmode="numeric" min="${Math.round(least / 1000)}" max="${Math.round(most / 1000)}" step="1" value="${Math.round((t.compactAt || 0) / 1000)}"
      data-compact="${name}" data-worker="${id}" aria-label="Thousands of tokens at which a ${name} run compacts its context">k tokens</label>
    ${notes.length ? `<small>${notes.join(' · ')}</small>` : ''}${advisor}</div>`;
}

// Whose mapping a worker uses: its own, or that of another worker on the same coding tool, in any project. Not a
// worker whose own chain of links leads back here: the link would close a loop (the server refuses one too). The
// worker it follows now stays in the list also when that worker went to another tool.
function followOptions(worker, all) {
  const byId = Object.fromEntries(all.map((w) => [w.id, w]));
  const leadsHere = (w) => {
    for (let at = w, n = 0; at && n < 50; at = byId[at.mapping?.follows], n += 1) if (at.id === worker.id) return true;
    return false;
  };
  const follows = worker.mapping?.follows || '';
  const offered = all.filter((w) => w.id !== worker.id && (w.id === follows || (w.provider === worker.provider && !leadsHere(w))));
  const label = (w) => `Same as ${workerLabel(w)}${w.of !== scope ? ` · ${w.of}` : ''}${w.provider !== worker.provider ? ' · on another tool now' : ''}`;
  return `<option value=""${follows ? '' : ' selected'}>Its own</option>${offered.map((w) => `<option value="${esc(w.id)}"${w.id === follows ? ' selected' : ''}>${esc(label(w))}</option>`).join('')}${
    follows && !byId[follows] ? `<option value="${esc(follows)}" selected>Same as worker ${esc(follows)}</option>` : ''}`;
}

function drawConfigOf(worker) {
  const id = esc(worker.id);
  $('config-title').textContent = `${workerLabel(worker)}${names.length > 1 ? ` on ${scope}` : ''}: config`;
  const tool = toolView(state, worker.provider);
  const has = mappingHas(tool);
  const mapping = worker.mapping || {};
  const takes = worker.takes || [];
  // The project's own complexities stand apart: the worker has them only in this project.
  const shared = takes.filter((t) => !t.own);
  const own = takes.filter((t) => t.own);
  const rows = (list) => list.map((t) => mappingRow(worker, t, tool, has)).join('');
  const all = pcWorkers();
  const advisorKey = `mapping:${worker.id}:`;
  const advisorRow = has.advisor ? `<div class="config-row${mapping.follows ? ' linked' : ''}${busyClass(advisorKey)}"${busyAttr(advisorKey)}><span class="config-name"><b>Advisor</b></span>
    <select data-advisor-model data-worker="${id}" aria-label="Model of the advisor"${mapping.follows ? ' disabled' : ''}>${pickList(tool.models || [], mapping.advisor, modelName)}</select>
    ${mapping.baseAdvisor && mapping.baseAdvisor !== mapping.advisor ? `<small>Default: ${esc(modelName(mapping.baseAdvisor))}</small>` : ''}</div>` : '';
  // The settings' `model` goes over the mapping of every worker on the project's default coding tool.
  const [model, effort] = (!worker.provider || toolName(state, worker.provider) === toolOf(state) ? state.settingsModel || '' : '').split('@');
  const override = model ? `<p class="takes-note">settings.json sets ${esc(modelName(model))}${effort ? ` · ${esc(effort)}` : ''}
    for every run of ${esc(scope)}: the models and efforts above are not in use.</p>` : '';
  const followKey = `mapping:${worker.id}`;
  put($('config-body'), `<div class="mapping-of${busyClass(followKey)}"${busyAttr(followKey)}>
      <label>Mapping<select data-follow="${id}" aria-label="Whose mapping worker ${id} uses">${followOptions(worker, all)}</select></label>
      ${toolBadge(toolName(state, worker.provider))}</div>
    ${own.length ? '<h3 class="config-group">In every project</h3>' : ''}
    <div class="config-head"><span>Complexity</span><span class="wide">Model</span><span class="wide${has.efforts ? '' : ' none'}">Effort</span><span${has.compact ? '' : ' class="none"'}>Compacts near</span></div>
    ${rows(shared)}${advisorRow}
    ${own.length ? `<h3 class="config-group project">Only in ${mark() || esc(scope)}</h3>${rows(own)}` : ''}
    ${override}`);
}

// ---- Details: the settings

// A project's settings that are the same for all its workers (docs/APP.md, Details): its colour, drawn in its scope.
// The colour shows only on the marks, so a PC with one project has no block. A worker's models are its own (its
// Config).
function settingsBlock() {
  return names.length > 1 ? `<section class="settings"><div class="settings-head${busyClass('color')}"${busyAttr('color')}><h2>${mark()}</h2>
    <input type="color" value="${colorOf(scope)}" data-color="${esc(scope)}" aria-label="Colour of ${esc(scope)}">
    ${ownColor(state) ? '<button data-color-reset>Default colour</button>' : ''}</div></section>` : '';
}

// ---- Questions

const questionTags = { pr: 'Holds a PR', ticket: 'Holds a ticket', question: 'Default is built', followup: 'New work' };

function questionCard(asked) {
  const q = takeBanner(asked);
  const key = esc(q.key);
  const details = q.details
    ? `<details data-key="more-${esc(scope)}-${key}"><summary>More</summary><div class="text">${markdown(q.details)}</div></details>` : '';
  const tag = questionTags[q.kind] + (q.kind === 'followup' && q.size ? ` · size ${esc(q.size)}` : '');
  const card = `question:${q.key}`;
  return `<article class="card question${q.blocking ? ' blocking' : ''}${busyClass(card)}"${busyAttr(card)}>${q.banner || ''}
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

// Now: the worker that does the ticket at once is the server's pick (row.now), or another of its list that the owner
// chooses in the dialog (row.now.able); without one, the button says why.
const nowButton = (row) => (row.now
  ? `<button data-now="${row.number}"${row.now.worker ? '' : ` disabled title="${esc(row.now.why)}"`}>Now</button>` : '');
// Drop: only a parked row has `blocks` (the tickets that wait on it), and only a parked row gets the cross.
const dropButton = (row) => (row.blocks
  ? `<button class="x" data-drop="${row.number}" title="Drop this ticket" aria-label="Drop ${esc(row.title)}">${icon('x')}</button>` : '');

function ticketRow(row) {
  const estimate = row.seconds ? `<span class="estimate">≈ ${duration(row.seconds)}${row.cost ? ` · ${dollars(row.cost)}` : ''}</span>` : '';
  const ready = row.reason === 'next up';
  const reason = row.reason ? `<span class="why${ready ? ' good' : ''}">${icon(ready ? 'next' : 'lock')}${esc(row.reason)}</span>` : '';
  const card = `ticket:${row.number}`;
  return `<div class="row${busyClass(card)}"${busyAttr(card)}><div class="what"><a href="${esc(row.url)}" target="_blank">${esc(row.title)}</a>
    <div class="meta">${mark()}${badges([row.repo, ...(row.areas || []), row.size, row.complexity])}${estimate}${reason}</div></div>${nowButton(row)}${dropButton(row)}${prioritySelect(row)}</div>`;
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
    <div class="meta">${mark()}${badges([kind, r.size, modelName(r.model), r.duration && duration(r.duration), r.cost > 0 && `$${Number(r.cost).toFixed(2)}`])}</div></div>
    <span class="when">${ago(r.at)}</span></div>`;
}

// ---- Accounts

const accountStates = {
  ready: ['good', 'check', 'Ready'], limit: ['warn', 'history', 'At its stop line'],
  signedout: ['bad', 'alert', 'Signed out'], unused: ['muted', 'pause', 'Not used'],
  // Out for another cause than its login: the chip names it (outNames), the card gives the refusal's text.
  refused: ['bad', 'alert', 'Takes no runs'],
};

// The provider's usage windows (the snapshot's `windows`, from limits.ps1): the account's own, then the ones of some
// models. Only a run on its models reads such a window, and it has its own stop line: from there no run gets one of
// them as its advisor, until the reset.
const usageWindows = () => state.windows || [];

// What each use in the account register means, in a word.
const useName = (use) => (use.startsWith('worker:') ? `worker ${use.slice(7)}` : { frontdesk: 'front desk', personal: 'you' }[use] || use);

// A guard: a human use of the account that keeps room under the stop line of one window (docs/QUEUE.md, The budget).
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
// at the handle and moves with it. Under the meter each guard has a slider: its share of the whole window. It keeps the
// part of that share for the time left, so its row gives both figures and the slider's track shows the part.
// Above the track stand the window's pick-up limits, where it has them, a small handle under the letter of each ticket
// size: from there the workers take no new ticket of that size. A run in flight goes on to the stop line.
// $inner goes under the meter, above the guards: the windows of some models under the account's last one. Such a
// window has one pick-up limit, under the name the provider gave it: from there no new run starts on its models, so
// the runs in flight end under the stop line and the advisor goes on.
function windowMeter(account, win, w, inner = '') {
  const key = win.name;
  const label = esc(win.title || win.name);
  const read = w.used != null;
  const stop = Math.round(w.stopAt * 100);
  const guards = w.guards || [];
  const keeps = guards.map((g) => `;--keep-${esc(g.use)}:${g.kept * 100}%`).join('');
  const rows = guards.map((g) => `<label class="guard ${esc(g.use)}">
      <span class="key"></span><span>${esc(guardNames[g.use] || g.use)}</span>
      <input type="range" min="0" max="50" value="${Math.round(g.share * 100)}" data-guard="${esc(g.use)}" data-account="${esc(account.name)}" data-left="${w.left}" aria-label="${esc(guardNames[g.use] || g.use)}: its share of the whole window" style="--pos:${g.share * 200}%">
      <span class="amount"><b>${percent(g.share)}</b><small>${keptNow(g.kept)}</small></span></label>`).join('');
  const scoped = !!win.models;
  const order = !w.pickUp ? [] : scoped ? Object.keys(w.pickUp) : sizes.filter((size) => size in w.pickUp);
  const picks = order.map((size) => `<input type="range" class="pick" min="0" max="100" value="${Math.round(w.pickUp[size] * 100)}" data-pick="${esc(size)}" data-account="${esc(account.name)}" data-window="${esc(key)}" aria-label="${label}: no new ${esc(size)} ticket from this share">
      <span class="flag" style="left:var(--pick-${esc(size)})">${esc(scoped ? size[0].toUpperCase() : size)}</span>`).join('');
  const limits = order.map((size) => `;--pick-${esc(size)}:${w.pickUp[size] * 100}%`).join('');
  const news = !order.length ? '' : scoped ? `<span>${order.map((name) => `New ${esc(name)} tickets to <b data-figure="${esc(name)}">${percent(w.pickUp[name])}</b>`).join(', ')}</span>`
    : `<span>New tickets: ${order.map((size) => `${size} to <b data-figure="${size}">${percent(w.pickUp[size])}</b>`).join(', ')}</span>`;
  // The window's length in days, or in hours for a short one.
  const days = (win.seconds || 0) / 86400;
  const whole = days >= 2 ? `${(w.left * days).toFixed(1)} of ${Math.round(days)} days` : `${(w.left * days * 24).toFixed(1)} of ${Math.round(days * 24)} hours`;
  const hint = rows ? `<div class="hint">${whole} left: a guard keeps ${percent(w.left)} of its share</div>` : '';
  return `<div class="window" style="--stop:${stop}%${keeps}${limits};--left:${w.left ?? 1}">
    <div class="window-head"><b>${label}</b><span>${read ? `${percent(w.used)} used` : 'no reading yet'}</span>
      <span class="when">${w.resetsAt ? `resets ${clock(w.resetsAt * 1000)}` : ''}</span></div>
    <div class="meter">
      <div class="fill" style="width:${Math.min(100, (w.used || 0) * 100)}%"></div>
      <div class="zones">${guards.map((g) => `<div class="kept ${esc(g.use)}"></div>`).join('')}<div class="off"></div></div>
      ${picks}
      <input type="range" min="0" max="100" value="${stop}" data-stop="${esc(account.name)}" data-window="${esc(key)}" aria-label="${label}: the stop line">
    </div>
    <div class="window-foot">${news}<span class="stop">${scoped ? 'Advisor stops' : 'Workers stop'} at <b>${percent(w.ceiling)}</b></span></div>${inner}${rows ? `<div class="guards">${rows}${hint}</div>` : ''}</div>`;
}

// An account's meters: its own windows, shortest first, and under the last one the windows of some models that it
// has a reading of. The card has two rows for them (the grid's subgrid): with one window an empty slot comes first, so
// the window stands where its neighbour's longest one does.
function accountMeters(a) {
  const own = usageWindows().filter((win) => !win.models && a[win.name]);
  const scoped = usageWindows().filter((win) => win.models && a[win.name]).map((win) => windowMeter(a, win, a[win.name])).join('');
  if (!own.length) return scoped;
  return '<div class="empty"></div>'.repeat(Math.max(0, 2 - own.length))
    + own.map((win, i) => windowMeter(a, win, a[win.name], i === own.length - 1 ? scoped : '')).join('');
}

// An email with only the first three letters of its name shown: the page is on screen in a call or in a screenshot.
const maskEmail = (email) => (email ? email.replace(/^([^@]{0,3})[^@]*/, '$1\u2022\u2022\u2022') : '');

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
  // Each only with a coding tool that has it (has): a tool with no sign-in for the page is signed in from a terminal.
  const buttons = a.status === 'signedout' && has(state, 'SignIn', 'ReadSignIn') ? [`<button class="primary" data-login="${name}">Sign in</button>`] : [];
  if (a.signedIn && has(state, 'Probe')) buttons.push(`<button data-ping="${name}" title="Sends the cheapest request: it starts the account's windows now and reads its usage">Ping</button>`);
  const card = `account:${a.name}`;
  // The picture of the account's coding tool behind the card, where its plugin has one.
  const art = state.tools?.[a.provider]?.card;
  return `<article class="card account ${tone}${art ? ' art' : ''}${busyClass(card)}" data-card="${name}"${busyAttr(card)}${art ? ` style="--art:url('${esc(art)}')"` : ''}>
    <div class="account-head"><strong>${renameable('account', a.name, a.name, a.name)}</strong>${a.plan ? `<span class="badge">${esc(a.plan)}</span>` : ''}
      <span class="chip ${tone}">${icon(glyph)}${words}</span>${cross('account', a.name, a.name)}</div>
    <div class="meta"><span class="email">${esc(a.signedIn ? maskEmail(a.email) : '')}</span>${toolBadge(toolOf(state))}${out}</div>
    ${accountMeters(a)}
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

// The project's environment in words: the titles of its plugins but the provider's, '' for a plain git repo.
const environment = (s) => inWords((s.plugins || []).filter((p) => !p.provider).map((p) => esc(p.title || p.name)));

function info(s) {
  const blocking = s.questions.filter((q) => q.blocking).length;
  const advisor = s.advisor;
  // What can differ between the PC's projects, for each of them: its coding tool (`of`, its snapshot).
  const per = s.per || [{ name: '', of: s }];
  const tools = [...new Set(per.map((p) => toolOf(p.of)).filter(Boolean))];
  return [
    section('In short', `<p>Workers are sessions of a coding tool on this PC${tools.length ? ` (${inWords(tools.map(esc))})` : ''}. Each builds tickets (GitHub issues) on its own, one at
      a time, in its own copy of the project${environment(s) ? `, with its environment (${environment(s)})` : ''}. It tests
      its work and opens a pull request (PR), and a merger merges the PR into main. You decide what to build; the scripts
      do the rest.</p>`),
    section('What needs you', items([
      `${setting('Questions', 'questions')}: only about the product (a rule, a look, what a user sees), never the workflow.
        A blocking question holds its PR or ticket until you answer (${blocking} now); answer the others when you like.
        Accept default takes the worker's proposal. Every question has a picture of what it is about. A new look comes
        as three candidates with a picture each, the first built in; tap a picture to step through them.`,
      `${setting('No blocking', 'workers')} (the switch on Workers, ${s.away ? 'on' : 'off'} now) is for the days you are
        not there, for every project on this PC. While it is on, no question holds a PR or a ticket: a worker builds its
        own default, and the question waits under Not blocking for you to keep or change. What already waits goes on
        the same way, and a stuck run gets one more try. Switch it off when you are back.`,
      `${setting('Stuck', 'queue')} runs (Queue) ended with no PR and no question. Nothing retries by itself, but for
        one try while No blocking is on: read the reason, then Retry (${s.stuck.length} now).`,
      `${setting('Accounts', 'accounts')} that are signed out or refuse runs: their workers wait until you sign in or
        give them another account.`,
      'Your phone gets a push for a blocking question, a stuck run, a limit, an account that is out and a merge.',
    ])),
    section('How a ticket goes through', `<ol>
      <li>A ticket with a priority (P0, P1, P2) waits in the ${setting('Queue', 'queue')}: the higher priority first,
        then the larger size, then the older ticket. With no priority it is Parked.</li>
      <li>A free worker first answers and rebases its own PRs, then takes the first queued ticket its account has room
        for. <b>Now</b> gives a ticket to a worker at once.</li>
      <li>Two tickets of the same area never run at the same time, and one "Blocked by" others waits until they close.</li>
      <li>A run ends in a PR, a question for you, or held at a limit. The merged PR closes its ticket; its follow-ups
        join the queue or wait under Questions.</li>
    </ol>`),
    section('Who builds what', `<p>A worker's ${setting('status', 'workers')}: Active takes tickets. Paused takes none and keeps its ticket; a run that waits at a usage limit or a stop line
        then stays stopped until you set the worker active. Disabled takes none, other workers take its
        ticket, and its plugins close what they opened for it. Force (the arrow on Next) gives a free worker its next
        ticket now, past the limits.</p>
      <p>A worker's ${setting('Config', 'workers')} sets which complexities it takes and how it runs each.${per.length > 1
        ? ` The project on a worker's ${setting('card', 'workers')} moves the worker to another project.` : ''}</p>`),
    section('Complexities', `<p>A ticket's complexity picks the model (no label: medium); its size (S, M, L) only says
      how much usage it takes. A worker's ${setting('Config', 'workers')} maps each complexity to a model and switches
      off the ones it does not take. A pick counts from the worker's next run.</p>
      <p>A worker can use another worker's mapping: the picks are then shared, the switches stay its own.${per.length > 1
        ? ' A complexity of one project\'s own has its row only there, and its pick waits there while the worker is elsewhere.' : ''}${toolHas(s).compact
        ? ' Compacts near is the context size at which the coding tool sums up the older part of a run.' : ''}</p>
      ${advisor?.complexities?.length ? `<p>An advisor gives a run a second opinion when the run asks for one. A complexity
        on the advisor's own model runs with none, and past the stop line of the advisor's window new runs start
        without it.</p>` : ''}`),
    section('Limits', `<p>Each account has the usage windows of its plan${(s.windows || []).length ? `: ${inWords((s.windows || []).map((win) => `${esc(win.title || win.name)}${win.models ? ' (some models only)' : ''}`))}` : ''}.
      The workers use all the room you give them and stop at the lines you set (${setting('Accounts', 'accounts')}). A
      run that reaches a stop line ends at its next checkpoint, and its session goes on when the account has room again;
      a run that the plan's own limit cuts off goes on after the reset.</p>`),
    section('In the background', `<p>Three scripts run on this PC as hidden Windows tasks from logon, and need nothing
      from you: a <b>worker script</b> for each worker, which picks its next job, starts the run and checks how it
      ended; the <b>merger</b>, which merges each worker PR that GitHub can merge and no question holds, and hands one
      that conflicts back to its worker; and <b>this page's server</b>, which reaches your phone through Tailscale and is
      not open to the internet.</p>
      <p>Only the runs use a model${has(s, 'Probe') ? ', but for Ping and a cheap usage reading of an idle account' : ''}.
        A change to the scripts loads between jobs, never in a run.</p>`),
    section('GitHub', `<p>GitHub holds the record: the tickets, the PRs, every question and answer. Labels steer the
      scripts: <b>P0, P1, P2</b>, <b>size</b>, <b>complexity</b> and <b>area</b> as above, <b>worker:N</b> for the worker
      that has the ticket, and <b>needs-owner</b>, <b>answered</b> and <b>needs-rebase</b> for what waits on whom.</p>
      <p>Workers start each comment with "Worker N:". Any other comment is yours and overrides the ticket: the run reads
        it at its next checkpoint and replies. GitHub builds and tests nothing; the run's own tests are the check.</p>`),
    section('The tabs', items([
      `${setting('Workers', 'workers')}: what each worker does now and takes next, its status, account${per.length > 1 ? ', project' : ''} and Config, and the No blocking switch. The last tile adds a worker; a card's cross removes a disabled worker, and its copy of the project stays on the PC unless you tick Delete in the dialog.`,
      `${setting('Accounts', 'accounts')}: usage and the limits above; drag a handle to move one. ${has(s, 'SignIn', 'ReadSignIn') ? 'The last tile adds an account and signs it in; a' : 'A'} card's cross removes an account that nothing uses.`,
      `${setting('Questions', 'questions')}: decisions for you, blocking first.`,
      `${setting('Queue', 'queue')}: Up next with why each ticket waits, Stuck, On hold and Parked.`,
      `${setting('History', 'history')}: merged PRs, and each run with its model, time and cost.`,
      `${setting('Details', 'details')}: ${per.length > 1 ? 'each project\'s colour, then this text' : 'this text'}.`,
    ])),
  ].join('');
}

// ---- The page

// A tab's count, also at 0; red when something there needs the owner.
function count(id, n, hot) {
  $(id).textContent = String(n);
  $(id).classList.toggle('hot', hot);
  $(id).classList.toggle('zero', !n);
}

const quiet = (text) => `<div class="quiet">${text}</div>`;

// Every tab shows every project ('') or the one its select names: one choice for all tabs, kept on the device.
const keep = (key, value) => { try { localStorage.setItem(key, JSON.stringify(value)); } catch (e) { /* private mode */ } };
const kept = (key) => { try { return JSON.parse(localStorage.getItem(key)); } catch (e) { return null; } };
let shownOf = kept('scriptorium-queue') || '';

// The owner's order of the worker and account cards (dragged on the page, kept in the PC's settings, so every device
// shows it). A card not in it goes after the others: workers in the order of their numbers, accounts in the settings'
// order. shortcut: a device's older order of its own shows until the first drag saves one; drop it once all have.
const oldOrder = kept('scriptorium-order') || {};
const orderOf = (kind) => (states[home]?.order?.[kind]?.length ? states[home].order[kind] : oldOrder[kind] || []);
const placeIn = (kind, a, b) => {
  const list = orderOf(kind);
  const [i, j] = [list.indexOf(a), list.indexOf(b)];
  return (i < 0) - (j < 0) || i - j;
};
const workerKey = ({ p, item }) => `${p}|${item.id}`;
const workersInOrder = () => all('workers').sort((a, b) => placeIn('workers', workerKey(a), workerKey(b)) || a.item.id - b.item.id || a.p.localeCompare(b.p));
// The PC's accounts. An account is one coding tool's, and a project's page gives the accounts of each tool it has a
// plugin for: the list is every project's, each account once, with the project that gave it (`of`). That project's
// server reads the account's login and takes its actions. This address's own project comes first.
const pcAccounts = () => {
  const seen = new Set();
  return [home, ...names.filter((p) => p !== home)].flatMap((p) => (states[p]?.accounts || [])
    .filter((a) => !seen.has(a.name) && seen.add(a.name)).map((a) => ({ ...a, of: p })));
};
const accountsInOrder = () => pcAccounts().sort((a, b) => placeIn('accounts', a.name, b.name));
// The coding tools a new account can be of, each once, with a project whose server has its provider: a project's
// default before its others, this address's project first. Each @{ project; name (its provider plugin's, '' in a
// snapshot from before `tools`); title; signIn (it signs an account in from the page) }.
const accountTools = () => {
  const seen = new Set();
  return [home, ...names.filter((p) => p !== home)].flatMap((p) => {
    const s = states[p];
    if (!s?.tools) return s?.provider ? [{ project: p, name: '', title: toolOf(s), signIn: has(s, 'SignIn', 'ReadSignIn') }] : [];
    return Object.entries(s.tools).sort(([, a], [, b]) => (b.title === s.provider) - (a.title === s.provider))
      .map(([name, t]) => ({ project: p, name, title: toolTitle(t.title), signIn: has(t, 'SignIn', 'ReadSignIn') }));
  }).filter((t) => !seen.has(t.title) && seen.add(t.title));
};

function render() {
  const s = states[home];
  const questions = all('questions');
  const blocking = questions.filter(({ item }) => item.blocking);
  const open = questions.filter(({ item }) => !item.blocking);
  // The workers side by side, in the owner's order.
  const workers = workersInOrder();
  const working = workers.filter(({ item }) => item.activity === 'running').length;
  const stuck = all('stuck');
  const loaded = names.every((p) => states[p].github);
  if (!names.includes(shownOf)) shownOf = '';
  const shown = ({ p }) => !shownOf || p === shownOf;
  // The tab counters are of the project the select shows, or of every project. Workers counts the workers with a run
  // in flight; Accounts (the PC's, so for every project) the accounts in use that are not out.
  const workersOf = workers.filter(shown);
  const blockingOf = blocking.filter(shown);
  const stuckOf = stuck.filter(shown);
  count('count-workers', workersOf.filter(({ item }) => item.activity === 'running').length, workersOf.some(({ item }) => item.activity === 'down'));
  count('count-questions', blockingOf.length || open.filter(shown).length, blockingOf.length > 0);
  count('count-queue', all('queued').filter(shown).length + stuckOf.length, stuckOf.length > 0);
  const accounts = pcAccounts();
  count('count-accounts', accounts.filter((a) => ['ready', 'limit'].includes(a.status) && a.uses.length).length,
    accounts.some((a) => ['signedout', 'refused'].includes(a.status) && (a.own || a.uses.length)));
  document.title = (blocking.length ? `(${blocking.length}) ` : '') + 'Scriptorium' + (working ? ` · ${working} working` : '');

  // Every tab has the same select at the same spot: every project, or one. Accounts are the PC's, so its select
  // changes nothing there.
  // All and each project, each with the count of its items in `list` when the tab has one.
  const projectPick = (label, list) => (names.length > 1 ? `<select data-shown${shownOf ? ` class="of" style="--of:${colorOf(shownOf)}"` : ''} aria-label="${label}">${
    [['', 'All'], ...names.map((p) => [p, p])].map(([value, text]) => `<option value="${esc(value)}"${shownOf === value ? ' selected' : ''}>${esc(text)}${
      list ? ` · ${list.filter(({ p }) => !value || p === value).length}` : ''}</option>`).join('')}</select>` : '');
  put($('workers-projects'), projectPick('The project of the workers', workers));
  put($('accounts-projects'), projectPick('The project shown'));
  put($('details-projects'), projectPick('The project of the details'));

  const workersShown = workers.filter(shown);
  // No blocking (docs/APP.md, Workers): the PC's switch, so this address's own project gives and saves it.
  const noBlocking = within(home, () => `<button class="take no-blocking${s.away ? ' on' : ''}${busyClass('away')}"${busyAttr('away')} data-away aria-pressed="${Boolean(s.away)}"
    title="${s.away ? 'No question stops work' : 'A question can stop work'}">${icon(s.away ? 'check' : 'lock')}No blocking</button>`);
  put($('all-buttons'), `<button data-status="active" data-worker="all">${icon('play')}All active</button>
    <button data-status="paused" data-worker="all">${icon('pause')}Pause all</button>${noBlocking}`);
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

  // The accounts are the PC's, each drawn as its own project gives it (pcAccounts).
  const code = $('login-code')?.value || '';
  const signIn = [home, ...names.filter((p) => p !== home)].find((p) => states[p]?.login) || home;
  // The sign-in in progress is on the server of the project that started it.
  put($('login-box'), within(signIn, () => tagged(signIn, loginBox(state.login))));
  // The tile only where the PC has a coding tool.
  put($('account-list'), (accountsInOrder().map((a) => within(a.of, () => tagged(a.of, withTool(a.provider, () => accountCard(a))))).join('') || quiet('No accounts in the settings.'))
    + (accountTools().length ? addTile('account', 'Add an account') : ''));
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
      per: names.filter((p) => !shownOf || p === shownOf).map((p) => ({ name: p, plugins: states[p].plugins, of: states[p] })),
    }));
  } catch (e) {
    text = quiet('The info could not be drawn from this state. Pull down or reload to fetch a new one.');
  }
  // Last on the page: Scriptorium's own page on GitHub (the address of README.md), not a project's.
  put($('info-body'), `${text}<p class="repo-link"><a href="https://github.com/KadaXuanwu/Scriptorium" target="_blank" rel="noopener">Scriptorium on GitHub</a></p>`);
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
  // A change the owner made moves smoothly from the old state to the new one; the 5 s refresh does not animate. Not
  // under an open dialog: the browser draws the moving parts (a card's status) above everything, also above the dialog.
  if (animate && document.startViewTransition && !document.querySelector('dialog[open]') && !matchMedia('(prefers-reduced-motion: reduce)').matches) document.startViewTransition(paint);
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
    // The action went through, but one part of it did not (a copy that stays): this stays up until the owner reads it.
    else if (result.note) ask('One part is not done', result.note);
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
  // Every account of the PC, under its coding tool while the PC has more than one (accountOptions): the worker runs
  // on the tool of the account it gets, in any project.
  const accounts = pcAccounts();
  // The command-line login, offered as on a worker's card: only while no entry is that login.
  const options = (accounts.every((a) => a.own) ? '<option value="">command line</option>' : '')
    + accountOptions(accounts, (a) => toolName(states[a.of], a.provider));
  // The project it works in, while the PC has two or more: the server of that project adds it.
  const pick = names.length > 1
    ? `<label>Project<select name="project">${names.map((p) => `<option${p === home ? ' selected' : ''}>${esc(p)}</option>`).join('')}</select></label>` : '';
  const values = await ask('Add a worker', 'It starts as Active. It takes tickets when its copy of the repo is made and its environment is ready.', 'Add worker', {
    fields: `${pick}<label>Account<select name="account">${options}</select></label>`,
  });
  if (values) await act(values.project || home, { action: 'add-worker', account: values.account || '' });
}

// One account more: its coding tool (a choice while the PC has more than one), its name and email, then the sign-in on
// this tab (loginBox). An account of a tool with no sign-in from the page is only added: a worker can go on it, and
// the owner signs the tool in from a terminal.
async function addAccount() {
  const tools = accountTools();
  if (!tools.length) return;
  const only = tools.length === 1 ? tools[0] : null;
  const signs = 'Then sign in as that account: this tab shows the link and a box for the code.';
  const byHand = 'has no sign-in from this page: sign it in from a terminal, with the tool\'s own command.';
  // The text is the picked tool's: with two or more tools it follows the list.
  const textOf = (t) => (t.signIn ? `It is signed in to ${t.title}. ${signs}` : `${t.title} ${byHand}`);
  const pick = only ? '' : `<label>Coding tool<select name="tool">${tools.map((t, i) => `<option value="${i}">${esc(t.title)}</option>`).join('')}</select></label>`;
  const email = only && !only.signIn ? '' : '<label>Email (optional)<input name="email" type="email" placeholder="Its email" autocomplete="off" autocapitalize="none"></label>';
  const answer = ask(only ? `Add a ${only.title} account` : 'Add an account', textOf(only || tools[0]), only && !only.signIn ? 'Add' : only ? 'Add and sign in' : 'Add', {
    fields: `${pick}<label>Name<input name="account" required pattern="[a-zA-Z0-9][a-zA-Z0-9\\-]{0,30}" title="Letters, digits and dashes"
        placeholder="e.g. temp1" autocomplete="off" autocapitalize="none"></label>${email}`,
  });
  const list = $('ask-fields').querySelector('[name=tool]');
  list?.addEventListener('change', () => { $('ask-text').textContent = textOf(tools[Number(list.value)]); });
  const values = await answer;
  if (!values) return;
  const tool = only || tools[Number(values.tool)];
  const account = values.account.trim().toLowerCase();
  const added = await act(tool.project, { action: 'login', account, email: (values.email || '').trim(), new: true, provider: tool.name });
  if (added && tool.signIn) $('login-box').scrollIntoView({ block: 'nearest' });
}

// Worker `id`'s copy of `project`, for the dialogs that can delete it: its folder's name and what it holds that GitHub
// does not have. Null when the worker has no copy there or the server does not answer: the dialog then has no choice.
async function copyOf(project, id) {
  try {
    const response = await fetch(api(project, `api/copy?worker=${encodeURIComponent(id)}`), { cache: 'no-store', signal: AbortSignal.timeout(8000) });
    const copy = await response.json();
    return copy.name ? copy : null;
  } catch (e) {
    return null;
  }
}

// The dialog's choice to delete that copy too, not ticked: the copy stays unless the owner ticks it. It names what
// the copy holds, so the owner knows what goes.
function deleteChoice(copy) {
  if (!copy) return '';
  const held = copy.work.length ? `It holds work that GitHub does not have: ${copy.work.join('; ')}.` : 'It holds no work that GitHub does not have.';
  return `<label class="check"><input type="checkbox" name="deleteCopy"><span>Delete ${esc(copy.name)} from the PC too. This is permanent. ${esc(held)}</span></label>`;
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
  } else {
    const values = await ask(title, `Its script stops and its card goes. Its copy of the repo stays on the PC: a new worker ${id} uses it again.`,
      'Remove', { danger: true, fields: deleteChoice(await copyOf(project, id)) });
    if (!values) return;
    await act(project, { action: 'remove-worker', worker: id, deleteCopy: !!values.deleteCopy }, {
      keys: [`worker:${id}`],
      after: (s) => { s.workers = s.workers.filter((w) => w.id !== id); },
      done: (s) => !s.workers.some((w) => w.id === id),
    });
  }
}

// Only an account nothing uses goes: its login is signed out.
async function removeAccount(name) {
  const account = pcAccounts().find((a) => a.name === name);
  if (!account) return;
  const title = `Remove ${name}?`;
  if (account.uses.length) {
    const users = account.uses.map((use) => ({ frontdesk: 'the front desk', personal: 'you' }[use] || useName(use)));
    await ask(title, `${inWords(users)} ${users.length > 1 || users[0] === 'you' ? 'use' : 'uses'} it. Move ${users.length > 1 ? 'them' : 'it'} to another account first.`
      .replace(/^./, (c) => c.toUpperCase()));
    return;
  }
  if (!(await ask(title, 'Its login is signed out, and its card goes.', 'Remove', { danger: true }))) return;
  await act(account.of, { action: 'remove-account', account: name }, {
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
// A run with a process. A held run (resetsAt: it waits for a reset, room, its account or the owner) already stopped.
const working = (w) => w.run && !w.resetsAt;

// Sends a status. Shown at once: the new status, or the target as pending while a run still works toward it.
function sendStatus(project, worker, to, how) {
  const mine = (s) => s.workers.filter((w) => worker === 'all' || w.id === worker);
  return act(project, { action: 'status', worker, to, how }, {
    keys: mine(states[project]).map((w) => `worker:${w.id}`),
    apply: (s) => mine(s).forEach((w) => {
      if (to !== 'active' && w.run && how !== 'now' && (how === 'finish' || working(w)) && w.status === 'active') w.pending = { to, how };
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
  // No choice while no run works: a pause only keeps a held run from resuming. 'checkpoint' ends no process ('now'
  // would end a held run's compaction). A disable still asks: After the ticket lets a held run resume and finish.
  if (to === 'active' || (!views.some(working) && (to === 'paused' || !views.some((w) => w.run)))) {
    statusTo(project, worker, to, to === 'active' ? '' : 'checkpoint');
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

// The advisor of a complexity in a worker's mapping (its Config): its switch and its effort without it, saved as one
// pick, as the model and effort are.
function setAdvisor(project, row, worker, name, on) {
  const fallback = row.querySelector('[data-fallback]').value;
  const same = (t) => t && t.advisorOn === on && (t.advisorFallback || '') === fallback;
  return act(project, { action: 'advisor', worker, complexity: name, on, fallback }, {
    keys: [`mapping:${worker}:${name}`],
    apply: (s) => { Object.assign(takeOf(s, worker, name), { advisorOn: on, advisorFallback: fallback }); },
    done: (s) => same(takeOf(s, worker, name)),
  });
}

// The project's colour (Details): #rrggbb, or '' for the one from its name.
const setColor = (project, value) => act(project, { action: 'color', value }, {
  keys: ['color'],
  apply: (s) => { s.color = value; },
  done: (s) => (s.color || '') === value,
});

// Renames in place (docs/APP.md): a field over the name. Enter or a click elsewhere saves, Escape keeps the name. The
// 5 s redraw waits while the field has focus (put). A worker's empty name gives back "Worker <id>".
function rename(label) {
  if (label.querySelector('input')) return;
  const { rename: kind, id, name } = label.dataset;
  const shown = label.textContent;
  const input = document.createElement('input');
  input.className = 'rename';
  input.value = name;
  input.maxLength = kind === 'worker' ? 30 : 31;
  input.setAttribute('aria-label', `New name of ${kind === 'worker' ? `worker ${id}` : `account ${id}`}`);
  label.replaceChildren(input);
  input.focus();
  input.select();
  let ended = false;
  const end = async (save) => {
    if (ended) return;
    ended = true;
    const value = kind === 'account' ? input.value.trim().toLowerCase() : input.value.trim();
    label.textContent = shown;
    if (!save || value === name || (kind === 'account' && !value)) return;
    const project = projectOf(label);
    if (kind === 'worker') {
      await act(project, { action: 'rename-worker', worker: id, name: value }, {
        keys: [`worker:${id}`],
        apply: (s) => { workerOf(s, id).name = value; },
        done: (s) => (workerOf(s, id)?.name || '') === value,
      });
    } else {
      // An account is the PC's, so every project's snapshot holds it: the new name shows in all of them, and stays
      // until none of their last snapshots has the old one, or a card of each name would show.
      await act(project, { action: 'rename-account', account: id, name: value }, {
        keys: [`account:${value}`],
        apply: () => {
          for (const s of Object.values(states)) {
            const account = s?.accounts?.find((a) => a.name === id);
            if (account) account.name = value;
            for (const w of s?.workers || []) if (w.account === id) w.account = value;
          }
        },
        done: (s) => !!accountOf(s, value) && names.every((p) => !fresh[p]?.accounts?.some((a) => a.name === id)),
      });
    }
  };
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === 'Escape') {
      e.preventDefault();
      end(e.key === 'Enter');
    }
  });
  input.addEventListener('blur', () => end(true));
}
document.addEventListener('dblclick', (e) => {
  const label = e.target.closest('[data-rename]');
  if (label) rename(label);
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && e.target.matches?.('[data-rename]')) rename(e.target);
});

// ---- Viewer
// A question's pictures one at a time, each in the same place at the same size: a step shows what differs between two
// choices. A tap on the picture, an arrow key or a swipe steps; the text under it is the choice's.
let viewed = { shots: [], at: 0 };
function view(step) {
  const n = viewed.shots.length;
  viewed.at = (viewed.at + step + n) % n;
  const shot = viewed.shots[viewed.at];
  $('viewer-img').src = shot.src;
  $('viewer-open').href = shot.src;
  $('viewer-text').innerHTML = shot.text;
  $('viewer-count').textContent = n > 1 ? `${viewed.at + 1} / ${n}` : 'Picture';
  document.querySelectorAll('#viewer [data-view]').forEach((b) => { b.hidden = n < 2; });
}
document.addEventListener('click', (e) => {
  if (e.target.closest('[data-view], #viewer-img')) return view(Number(e.target.closest('[data-view]')?.dataset.view || 1));
  const shot = e.target.closest('a.shot');
  if (!shot || e.ctrlKey || e.metaKey || e.shiftKey) return;
  e.preventDefault();
  // The steps go through the card's choices; the banner is not one of them and shows alone.
  const all = shot.matches('.banner') ? [shot] : [...(shot.closest('.question') || shot.closest('.text')).querySelectorAll('a.shot:not(.banner)')];
  viewed = { at: all.indexOf(shot), shots: all.map((a) => ({ src: a.href, text: a.parentElement.classList.contains('choice') ? a.nextElementSibling.innerHTML : '' })) };
  view(0);
  $('viewer').showModal();
});
$('viewer').addEventListener('keydown', (e) => {
  if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') view(e.key === 'ArrowLeft' ? -1 : 1);
});
let viewerTouch = 0;
$('viewer').addEventListener('touchstart', (e) => { viewerTouch = e.touches[0].clientX; }, { passive: true });
$('viewer').addEventListener('touchend', (e) => {
  const moved = e.changedTouches[0].clientX - viewerTouch;
  if (Math.abs(moved) > 40) view(moved > 0 ? -1 : 1);
});
// ---- Viewer end

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
      keys: [`worker:${data.worker}`, `mapping:${data.worker}:${data.take}`],
      apply: (s) => { takeOf(s, data.worker, data.take).on = on; },
    });
  } else if (data.away !== undefined) {
    // What waits now goes on at once and cannot be taken back, so the owner confirms it.
    const on = target.getAttribute('aria-pressed') !== 'true';
    const counted = (n, word) => (n ? `${n} ${word}${n === 1 ? '' : 's'}` : '');
    const blocking = all('questions').filter(({ item }) => item.blocking).length;
    const stuck = all('stuck').length;
    const waits = inWords([counted(blocking, 'blocking question'), counted(stuck, 'stuck run')].filter(Boolean));
    if (on && waits && !await ask('No blocking', `${waits} wait${blocking + stuck === 1 ? 's' : ''} now. A question goes on with the worker's default and comes back under Not blocking; a stuck run gets one more try. This is for every project on this PC.`, 'Switch on')) return;
    await act(home, { action: 'away', on }, {
      keys: ['away'],
      apply: (s) => { s.away = on; },
      done: (s) => Boolean(s.away) === on,
    });
  } else if (data.advisor) {
    await setAdvisor(project, target.closest('.config-row'), data.worker, data.advisor, target.getAttribute('aria-pressed') !== 'true');
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
  } else if (data.now) {
    const number = Number(data.now);
    const row = rowOf(states[project], number);
    const pick = row?.now;
    if (!pick?.worker) return;
    // Every worker that can take it, the server's pick first. Each runs the ticket on the model of its own mapping.
    const able = pick.able?.length ? pick.able : [pick];
    const named = (p) => workerLabel(workerOf(states[project], p.worker) || { id: p.worker });
    const how = (p) => `${p.stops
      ? `${named(p)} ends its run of "${p.title}" at its next checkpoint and takes this ticket. That ticket goes back to the queue and starts fresh from its handoff comment.`
      : `${named(p)} is free and takes it at its next poll, before its other jobs.`} Its run does not stop at the account's stop line.${
      p.busy?.length ? ` ${inWords(p.busy)} ${p.busy.length > 1 ? 'are' : 'is'} busy with another ticket: the two can change the same files.` : ''}`;
    const runOn = (p) => within(project, () => runModel(takeOf(states[project], p.worker, row.complexity) || {}));
    const fields = able.length > 1 ? `<label>Worker<select name="worker">${able.map((p, i) => `<option value="${esc(p.worker)}"${i ? '' : ' selected'}>${
      esc([named(p), runOn(p), p.stops ? 'in a run' : 'free'].filter(Boolean).join(' · '))}</option>`).join('')}</select></label>` : '';
    const asked = ask(`Do "${row.title}" now?`, how(pick), 'Do it now', { fields });
    // The text is of the worker that the list shows.
    $('ask-fields').querySelector('select')?.addEventListener('change', (ev) => { $('ask-text').textContent = how(able.find((p) => p.worker === ev.target.value)); });
    const values = await asked;
    if (!values) return;
    const chosen = able.find((p) => p.worker === values.worker) || pick;
    await act(project, { action: 'now', number, worker: chosen.worker }, {
      keys: [`ticket:${number}`],
      apply: (s) => { const r = rowOf(s, number); if (r) Object.assign(r, { taken: chosen.worker, now: null, reason: `worker ${chosen.worker} does it now` }); },
      done: (s) => !rowOf(s, number) || !!rowOf(s, number).taken,
    });
  } else if (data.drop) {
    const number = Number(data.drop);
    const row = rowOf(states[project], number);
    if (!row) return;
    const n = row.blocks?.length || 0;
    const waits = n ? ` ${inWords(row.blocks.map((b) => `#${b}`))} ${n > 1 ? 'wait' : 'waits'} on it in a Blocked by line and ${n > 1 ? 'stop' : 'stops'} waiting.` : '';
    if (!(await ask(`Drop "${row.title}"?`, `It closes on GitHub as not planned, with a comment, and leaves Parked. Reopen it on GitHub to park it again.${waits}`,
      'Drop', { danger: true }))) return;
    await act(project, { action: 'drop', number }, {
      keys: [`ticket:${number}`],
      after: (s) => { s.parked = s.parked.filter((r) => r.number !== number); },
      done: (s) => !s.parked.some((r) => r.number === number),
    });
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
    await act(project, { action: 'login', account: data.login }, { keys: [`account:${data.login}`] });
  } else if (data.loginCode !== undefined) {
    const code = $('login-code').value.trim();
    if (!code) { toast('Paste the code first'); return; }
    target.disabled = true;
    if (await act(project, { action: 'login-code', code })) $('login-code').value = '';
  } else if (data.loginCancel !== undefined) {
    if (await ask('Cancel the sign-in?', 'The account stays as it is.', 'Cancel the sign-in')) await act(project, { action: 'login-cancel' });
  } else if (data.ping) {
    await act(project, { action: 'ping', account: data.ping }, { keys: [`account:${data.ping}`] });
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
    // The focus keeps the 5 s refresh from a redraw under the finger (put).
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
    if (drag && e.pointerId === drag.id) endDrag(e.type === 'pointerup');
  });
}

// Reorder: a worker's or an account's card moves when held on its empty space (not on a control, a meter or text) and
// dragged, with a mouse at once, on a touch screen after a hold, as a slider. Letting go keeps the order on the device.
function cardToDrag(target) {
  const card = target.closest?.('#worker-list > [data-card], #account-list > [data-card]');
  if (!card || card.inert || target.closest('a, button, select, input, textarea, label, [data-rename], .meter')) return null;
  // Text stays selectable: only a part with no text of its own starts a drag.
  return [...target.childNodes].some((n) => n.nodeType === Node.TEXT_NODE && n.textContent.trim()) ? null : card;
}
const motionMs = () => (matchMedia('(prefers-reduced-motion: reduce)').matches ? 0 : 150);
function armDrag() {
  const { card } = drag;
  if (!card.isConnected) return endDrag(false);
  drag.armed = true;
  getSelection().removeAllRanges();
  // The card keeps the point it was taken by under the pointer, and shrinks toward it.
  const r = card.getBoundingClientRect();
  [drag.gx, drag.gy] = [drag.x - r.left, drag.y - r.top];
  card.style.transformOrigin = `${drag.gx}px ${drag.gy}px`;
  card.classList.add('dragging');
  document.documentElement.classList.add('dragging-cards');
  followDrag(drag.x, drag.y);
  if (drag.touch) navigator.vibrate?.(10);
}
// The card under the pointer, from its place in the list (the transform left out).
function followDrag(x, y) {
  const { card } = drag;
  card.style.transform = '';
  const r = card.getBoundingClientRect();
  card.style.transform = `translate(${x - drag.gx - r.left}px, ${y - drag.gy - r.top}px) scale(0.95)`;
}
function endDrag(drop) {
  clearTimeout(drag.timer);
  const { card, list, armed } = drag;
  drag = null;
  if (!armed) return;
  document.documentElement.classList.remove('dragging-cards');
  let save = null;
  if (drop) {
    const kind = list.id === 'worker-list' ? 'workers' : 'accounts';
    const full = kind === 'workers' ? workersInOrder().map(workerKey) : accountsInOrder().map((a) => a.name);
    const moved = [...list.querySelectorAll(':scope > [data-card]')].map((c) => c.dataset.card).filter((k) => full.includes(k));
    // The cards the project select hides keep their places: the shown ones fill the places the shown ones had.
    const shownKeys = new Set(moved);
    let i = 0;
    const next = full.map((k) => (shownKeys.has(k) ? moved[i++] : k));
    save = () => act(home, { action: 'order', kind, list: next }, {
      keys: [`order:${kind}`],
      apply: (s) => { s.order = { ...s.order, [kind]: next }; },
      done: (s) => (s.order?.[kind] || []).join('\n') === next.join('\n'),
    });
  }
  // The card glides into its place, then the list is drawn again in the new order, which the PC's settings keep.
  const from = card.style.transform;
  card.style.transform = '';
  card.animate([{ transform: from }, { transform: 'none' }], { duration: motionMs(), easing: 'ease-out' }).finished
    .catch(() => {}).then(() => {
      card.classList.remove('dragging');
      drawn.delete(list);
      if (save) save();
      else render();
    });
}
document.addEventListener('pointerdown', (e) => {
  if (hold || drag || e.button !== 0) return;
  const card = cardToDrag(e.target);
  if (!card) return;
  drag = { card, list: card.parentElement, id: e.pointerId, x: e.clientX, y: e.clientY, armed: false, touch: e.pointerType !== 'mouse' };
  if (drag.touch) drag.timer = setTimeout(armDrag, holdMs);
});
document.addEventListener('pointermove', (e) => {
  if (!drag || e.pointerId !== drag.id) return;
  if (!drag.armed) {
    if (Math.hypot(e.clientX - drag.x, e.clientY - drag.y) <= 8) return;
    // A finger that moved before the hold was over scrolls.
    if (drag.touch) return endDrag(false);
    armDrag();
    if (!drag) return;
  }
  // The card under the pointer, past the moved one; one still sliding waits, so two cards never swap back and forth.
  const over = document.elementsFromPoint(e.clientX, e.clientY).map((el) => el.closest('[data-card]'))
    .find((c) => c && c !== drag.card && c.parentElement === drag.list);
  if (over && !over.getAnimations().length) {
    const others = [...drag.list.children].filter((c) => c !== drag.card);
    const before = others.map((c) => c.getBoundingClientRect());
    if (drag.card.compareDocumentPosition(over) & Node.DOCUMENT_POSITION_FOLLOWING) over.after(drag.card);
    else over.before(drag.card);
    // The others slide from their old places to their new ones.
    others.forEach((c, i) => {
      const after = c.getBoundingClientRect();
      const [dx, dy] = [before[i].left - after.left, before[i].top - after.top];
      if (dx || dy) c.animate([{ transform: `translate(${dx}px, ${dy}px)` }, { transform: 'none' }], { duration: motionMs(), easing: 'ease-out' });
    });
  }
  followDrag(e.clientX, e.clientY);
});
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
  if (hold?.armed || drag?.armed || e.touches.length !== 1 || dy < 0 || (!pull.by && Math.abs(dx) > Math.abs(dy))) {
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

// An armed slider or card holds the page still, and a long hold opens no menu.
document.addEventListener('touchmove', (e) => { if (hold?.armed || drag?.armed) e.preventDefault(); }, { passive: false });
document.addEventListener('contextmenu', (e) => { if (hold || drag) e.preventDefault(); });

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
    await act(project, { action: 'assign', worker: data.assign, account }, { keys: [`worker:${data.assign}`], apply: (s) => {
        // The worker's coding tool follows its account's.
        Object.assign(workerOf(s, data.assign), { account }, s.accounts.find((a) => a.name === account)?.provider && { provider: s.accounts.find((a) => a.name === account).provider });
      } });
  } else if (data.move) {
    // The card shows the worker's own project until the move is done: the next snapshots show it in the new one.
    const target = e.target.value;
    e.target.value = project;
    e.target.blur();
    const text = `It keeps its number, its account, its status, its complexities and its mapping. Its copy of ${target} is made at its first move there. `
      + `Its copy of ${project} stays on the PC, and the other workers of ${project} take its open PRs.`;
    const values = await ask(`Move worker ${data.move} to ${target}?`, text, 'Move', { fields: deleteChoice(await copyOf(project, data.move)) });
    if (values) await act(target, { action: 'move-worker', worker: data.move, from: project, deleteCopy: !!values.deleteCopy });
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
    await act(project, { action: 'stop-at', account: data.stop, window: data.window, value }, {
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
    await act(project, { action: 'pick-up', account: data.account, window: data.window, size: data.pick, value }, {
      keys: [`account:${data.account}`],
      apply: (s) => { accountOf(s, data.account)[data.window].pickUp[data.pick] = value; },
    });
  } else if (data.follow) {
    // Whose mapping a worker uses (its Config): another worker's, or its own again, which starts from the picks it
    // ran on.
    e.target.blur();
    const worker = data.follow;
    const target = e.target.value;
    await act(project, { action: 'follow', worker, target }, {
      keys: [`mapping:${worker}`],
      apply: (s) => { const w = workerOf(s, worker); w.mapping = { ...w.mapping, follows: target }; },
      done: (s) => (workerOf(s, worker)?.mapping?.follows || '') === target,
    });
  } else if (data.compact) {
    // The compact size of a complexity in a worker's mapping: typed in thousands of tokens, saved in tokens.
    e.target.blur();
    const name = data.compact;
    const value = Math.round(Number(e.target.value));
    if (!(value >= e.target.min && value <= e.target.max)) {
      toast(`Between ${e.target.min}k and ${e.target.max}k tokens`);
      e.target.value = Math.round(takeOf(states[project], data.worker, name).compactAt / 1000);
      return;
    }
    await act(project, { action: 'compact-at', worker: data.worker, complexity: name, value: value * 1000 }, {
      keys: [`mapping:${data.worker}:${name}`],
      apply: (s) => { takeOf(s, data.worker, name).compactAt = value * 1000; },
      done: (s) => takeOf(s, data.worker, name)?.compactAt === value * 1000,
    });
  } else if (data.runModel || data.runEffort) {
    // The model and effort of a complexity in a worker's mapping: the two lists of its row, saved as one pick.
    e.target.blur();
    const name = data.runModel || data.runEffort;
    const row = e.target.closest('.config-row');
    const pick = { model: row.querySelector('[data-run-model]').value, effort: row.querySelector('[data-run-effort]').value };
    // A model with efforts of its own that lack the one shown takes its own default.
    const own = toolView(states[project], workerOf(states[project], data.worker)?.provider)?.perModel?.[pick.model];
    if (own && !own.efforts.includes(pick.effort)) pick.effort = own.effort;
    const same = (t) => t && t.model === pick.model && (t.effort || '') === pick.effort;
    await act(project, { action: 'model', worker: data.worker, complexity: name, ...pick }, {
      keys: [`mapping:${data.worker}:${name}`],
      apply: (s) => { Object.assign(takeOf(s, data.worker, name), pick); },
      done: (s) => same(takeOf(s, data.worker, name)),
    });
  } else if (data.fallback) {
    e.target.blur();
    const t = takeOf(states[project], data.worker, data.fallback);
    await setAdvisor(project, e.target.closest('.config-row'), data.worker, data.fallback, t.advisorOn ?? Boolean(t.advisor));
  } else if (data.advisorModel !== undefined) {
    // The advisor's model in a worker's mapping.
    e.target.blur();
    const model = e.target.value;
    await act(project, { action: 'advisor-model', worker: data.worker, model }, {
      keys: [`mapping:${data.worker}:`],
      apply: (s) => { const w = workerOf(s, data.worker); w.mapping = { ...w.mapping, advisor: model }; },
      done: (s) => workerOf(s, data.worker)?.mapping?.advisor === model,
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
        const keep = (s.windows || []).find((win) => win.keep)?.name;
        for (const a of s.accounts) {
          const w = a[keep];
          if (!w) continue;
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
setInterval(() => { if (!document.hidden) refresh(); }, 5000);
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
