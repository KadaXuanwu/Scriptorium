// The queue app's page (docs/APP.md): renders /api/state every 10 s while visible, posts the owner's actions.
'use strict';

const $ = (id) => document.getElementById(id);
// The last snapshot as the server sent it, and what the page shows: that snapshot with the owner's unconfirmed
// actions on top.
let fresh = null;
let state = null;
let fetches = 0;
// The owner's actions that the server's state does not show yet, by the card each one changes. The page shows an
// action at once and marks its card busy until a snapshot confirms it. Each: apply (the change, shown from the
// click), after (a change shown once the server said yes), done (true when a snapshot shows the action; without it,
// the first snapshot fetched after the yes confirms), responded, seq (the fetch count at the yes), until.
const ops = new Map();
const busyClass = (key) => (ops.has(key) ? ' busy' : '');
const busyAttr = (key) => (ops.has(key) ? ' inert aria-busy="true"' : '');
const workerOf = (s, id) => s.workers.find((w) => w.id === id);
const accountOf = (s, name) => s.accounts.find((a) => a.name === name);
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
        const src = `/api/shot?branch=${branch}&amp;name=${name}`;
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
  const open = opened.has(String(worker.id));
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
    class="${worker.status === s ? 'on' : ''}${worker.pending?.to === s ? ' pending' : ''}"${worker.status === s ? ` style="view-transition-name:seg-${id}"` : ''}>${icon(statusIcons[s])}<span>${statusNames[s]}</span></button>`).join('');
  const pending = worker.pending ? `<div class="pending-note">${pendingVerbs[worker.pending.to]} ${howNames[worker.pending.how]}</div>` : '';

  // The complexity switches of the worker (docs/QUEUE.md, Settings, `workers.<id>.complexity`): a menu with one for
  // each ticket complexity and the model its runs use. Off: the worker takes no new ticket of it and leaves the
  // answers and rebases of its PRs of it (`jobs`) until it is on again.
  const all = worker.takes || [];
  const on = all.filter((t) => t.on).length;
  const takes = `<details class="menu" data-key="takes-${id}"><summary aria-label="Tickets worker ${id} takes">${icon('queue')}Takes ${on}/${all.length}</summary>
      <div class="pop">${all.map((t) => `<button class="take${t.on ? ' on' : ''}" data-take="${esc(t.name)}" data-worker="${id}" aria-pressed="${t.on}">
        ${icon(t.on ? 'check' : 'lock')}<span><b>${esc(t.name)}</b><small>${esc(modelName(t.model))}${t.effort ? ` · ${esc(t.effort)}` : ''}${!t.on && t.jobs ? ` · holds ${t.jobs} PR job${t.jobs === 1 ? '' : 's'}` : ''}</small></span></button>`).join('')}</div></details>`;

  const accounts = state.accounts || [];
  const options = accounts.map((a) => `<option value="${esc(a.name)}"${a.name === worker.account ? ' selected' : ''}>${esc(a.name)}${outMark[a.status] || ''}</option>`);
  // A worker in no entry runs on the command-line login; offered only while no entry is that login.
  if (!worker.account || accounts.every((a) => a.own)) options.unshift(`<option value=""${worker.account ? '' : ' selected'}>command line</option>`);

  const card = `worker:${worker.id}`;
  return `<article class="card worker ${esc(worker.status)}${open ? ' open' : ''}${busyClass(card)}"${busyAttr(card)}>
    <div class="worker-head"><span class="avatar">${id}</span><div class="who"><strong>Worker ${id}</strong>
      <span class="doing ${tone}">${icon(glyph)}${words}</span></div>
      <button class="round more" data-more="${id}" aria-expanded="${open}" aria-label="Details of worker ${id}">${icon('down')}</button>${cross('worker', id, `worker ${id}`)}</div>
    <div class="status"><div class="seg" role="group" aria-label="Status of worker ${id}">${seg}</div>${pending}</div>
    <div class="worker-tools"><label>${icon('accounts')}<select data-assign="${id}" aria-label="Account of worker ${id}">${options.join('')}</select></label>
      ${takes}<button data-steps="${id}">${icon('steps')}Steps</button></div>
    <div class="slot now"><span class="slot-label">Now</span><div class="slot-body">${now}</div></div>
    <div class="slot next"><span class="slot-label">Next</span><div class="slot-body">${nextBody}</div>${force}</div></article>`;
}

// ---- Questions

const questionTags = { pr: 'Holds a PR', ticket: 'Holds a ticket', question: 'Default is built', followup: 'New work' };

function questionCard(q) {
  const key = esc(q.key);
  const details = q.details
    ? `<details data-key="more-${key}"><summary>More</summary><div class="text">${markdown(q.details)}</div></details>` : '';
  const tag = questionTags[q.kind] + (q.kind === 'followup' && q.size ? ` · size ${esc(q.size)}` : '');
  const card = `question:${q.key}`;
  return `<article class="card question${q.blocking ? ' blocking' : ''}${busyClass(card)}"${busyAttr(card)}>
    <div class="question-head"><span class="tag">${tag}</span><a href="${esc(q.url)}" target="_blank">${esc(q.title)}</a></div>
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
    <div class="meta">${badges([row.repo, ...(row.areas || []), row.size, row.complexity])}${estimate}${reason}</div></div>${prioritySelect(row)}</div>`;
}


const stuckRow = (item) => `<div class="row${busyClass(`stuck:${item.key}`)}"${busyAttr(`stuck:${item.key}`)}><div class="what"><a href="${esc(item.url)}" target="_blank">${esc(item.title)}</a>
  <div class="meta">${badges([item.worker && `worker ${item.worker}`])}</div><div class="reason">${markdown(item.reason)}</div></div>
  <button data-retry="${esc(item.key)}">${icon('retry')}Retry</button></div>`;

const heldRow = (item) => `<div class="row"><div class="what"><a href="${esc(item.url)}" target="_blank">${esc(item.title)}</a></div></div>`;

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
    <div class="window-foot">${news}<span class="stop">${fable ? 'Advisor stops' : 'Workers stop'} at <b>${percent(w.ceiling)}</b></span></div>${inner}${rows ? `<div class="guards">${rows}${hint}</div>` : ''}</div>`;
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
  const buttons = [`<button data-login="${name}"${a.signedIn ? '' : ' class="primary"'}>${a.signedIn ? 'Sign in again' : 'Sign in'}</button>`];
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

// ---- Info

// What the queue does and what to expect, for someone who does not know it: plain sections, no
// cards. Each value the owner sets is a link to the tab that sets it. Every setting and reading comes from the
// snapshot, never typed into the text, and a change to a queue rule changes this text in the same pass (docs/APP.md,
// Info). Drawn last, from a snapshot that may be older than this code (stored on the device): each field has a fallback,
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
    : fable.used >= fable.ceiling ? ' Now past both lines: no design ticket starts, and new runs get no advisor.'
      : fable.used >= design ? ' Now past the design line: no design ticket starts, and new runs still get the advisor.' : '';
  const lines = [
    five.pickUp && `<b>5 hours:</b> ${now(five)}No new L ticket from ${at(five.pickUp.L)}, no new M from ${at(five.pickUp.M)},
      no new S from ${at(five.pickUp.S)}. Workers stop at ${at(five.ceiling)}.`,
    week.stopAt != null && `<b>Week:</b> ${now(week)}${guards.length
      ? `Your stop line is ${at(week.stopAt)}. Below it the workers keep room for people: ${guards.join(' and ')} of a
        whole week, less as the reset comes closer. Now that is ${percent(week.kept)}, so the workers stop at ${percent(week.ceiling)}.`
      : `Workers stop at ${at(week.stopAt)}.`}`,
    fable ? `<b>Fable week:</b> ${now(fable)}Only a Fable run updates this reading. No new design ticket from
        ${at(design)}. No advisor for new runs from ${at(fable.ceiling)}.${fableNow}`
      : '<b>Fable week:</b> no reading yet. The first Fable run gives one.',
  ];
  const who = (a.uses || []).map(useName).join(', ');
  return `<h3>${esc(a.name)}${who ? ` <span class="sub">${esc(who)}</span>` : ''}</h3>${items(lines)}`;
}

// Claude Code compacts a context this many tokens before its compact window (docs/CONFIG.md, The compact window).
const COMPACT_BUFFER = 33000;

// The project's environment in words: its plugins' titles, '' for a plain git repo.
const environment = (s) => inWords((s.plugins || []).map((p) => esc(p.title || p.name)));

function info(s) {
  const blocking = s.questions.filter((q) => q.blocking).length;
  const advisor = s.advisor;
  const working = (s.accounts || []).filter((a) => (a.uses || []).some((u) => u.startsWith('worker:')));
  const plugins = s.plugins || [];
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
      `${setting('Accounts', 'accounts')} that are signed out or refuse runs: their workers wait. Sign in again, or give the
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
      return `Worker ${esc(w.id)}: ${setting(esc(statusNames[w.status] || w.status), 'workers')}${w.account ? ` on ${esc(w.account)}` : ''}${off.length
        ? `, takes no ${setting(esc(off.join(', ')), 'workers')} tickets` : ''}.`;
    }))}
      <p>Active takes tickets. Paused takes none and keeps its ticket. Disabled takes none, and other workers take its
        ticket. Force (the arrow on Next) gives a free worker its next ticket now, past the limits.</p>
      <p>A worker's Takes menu shows the model of each complexity for that worker, where the settings change it.</p>`),
    section('Complexities', `<p>The complexity of a ticket chooses the model. The size (S, M, L) only says how much usage
      it takes. A ticket with no complexity label is medium.</p>
      ${items((s.complexities || []).map((c) => `<b>${esc(c.name)}</b> (${esc(c.description || c.name)}): ${esc(modelName(c.model))},
        ${esc(c.effort)} effort${c.advisor ? `, with ${esc(modelName(c.advisor))} as advisor${c.advisorFallback
          ? `; ${esc(c.advisorFallback)} effort while the advisor is not there` : ''}` : ''}. Its context is
        compacted near ${setting(`${Math.round((c.compactWindow - COMPACT_BUFFER) / 1000)}k tokens`, 'workers')}.`))}
      ${advisor?.complexities?.length ? `<p>A run with an advisor asks it for a second opinion when it decides to; you do
        not see the advice. A run keeps its advisor to its end; past the Fable advisor line (Limits), new runs start
        without one.</p>` : ''}`),
    section('Plugins', plugins.length
      ? items(plugins.map((p) => `<b>${esc(p.title || p.name)}</b> ${esc(p.version)}: ${esc(p.description)}`))
      : '<p>None: a plain git repo.</p>'),
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
      `${setting('Workers', 'workers')}: what each worker does now and takes next, its status, account and Takes. The last tile adds a worker; the cross on a card removes a disabled worker, and its copy of the project stays on the PC.`,
      `${setting('Accounts', 'accounts')}: usage and the limits above; drag a handle to move one. The last tile adds an account and signs it in; the cross on a card removes an account that nothing uses.`,
      `${setting('Questions', 'questions')}: decisions for you, blocking first.`,
      `${setting('Queue', 'queue')}: Up next with why each ticket waits, Stuck, On hold and Parked.`,
      `${setting('History', 'history')}: merged PRs, and each run with its model, time and cost.`,
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

function render() {
  const s = state;
  const blocking = s.questions.filter((q) => q.blocking);
  const open = s.questions.filter((q) => !q.blocking);
  const working = s.workers.filter((w) => w.activity === 'running').length;
  // Workers counts the workers with a run in flight; Accounts the accounts in use that are not out.
  count('count-workers', working, s.workers.some((w) => w.activity === 'down'));
  count('count-questions', blocking.length || open.length, blocking.length > 0);
  count('count-queue', s.queued.length + s.stuck.length, s.stuck.length > 0);
  count('count-accounts', s.accounts.filter((a) => ['ready', 'limit'].includes(a.status) && a.uses.length).length,
    s.accounts.some((a) => ['signedout', 'refused'].includes(a.status) && (a.own || a.uses.length)));
  document.title = (blocking.length ? `(${blocking.length}) ` : '') + 'Scriptorium' + (working ? ` · ${working} working` : '');

  const active = s.workers.filter((w) => w.status === 'active').length;
  $('workers-sub').textContent = `${working} working · ${active} of ${s.workers.length} active`;
  put($('all-buttons'), `<button data-status="active" data-worker="all">${icon('play')}All active</button>
    <button data-status="paused" data-worker="all">${icon('pause')}Pause all</button>`);
  put($('worker-list'), (s.workers.map(workerCard).join('') || quiet('No worker has reported yet.')) + addTile('worker', 'Add a worker'));
  // Where a run's context is compacted (docs/CONFIG.md, The compact window): the field takes that size in thousands
  // of tokens, and the server gets the window, which is the buffer larger.
  put($('run-settings'), s.compactWindow ? `<label class="compact">Runs compact their context near
    <input type="number" inputmode="numeric" min="${(100000 - COMPACT_BUFFER) / 1000}" max="${(1000000 - COMPACT_BUFFER) / 1000}" step="1"
      value="${Math.round((s.compactWindow - COMPACT_BUFFER) / 1000)}" data-compact="" aria-label="Thousands of tokens at which a run compacts its context">
    k tokens</label><p class="hint">Claude Code then replaces the older part with a summary. A larger size keeps more of the work in
    view and uses more for each turn. It applies from the next run.</p>` : '');

  // An answer being typed survives a redraw of its list.
  const typed = {};
  document.querySelectorAll('#questions textarea').forEach((t) => { typed[t.dataset.key] = t.value; });
  const loading = quiet('Loading from GitHub...');
  $('blocking-title').textContent = `Blocking · ${blocking.length}`;
  $('open-title').textContent = `Not blocking · ${open.length}`;
  put($('blocking-list'), s.github ? (blocking.map(questionCard).join('') || quiet('No question blocks any work.')) : loading);
  put($('open-list'), s.github ? (open.map(questionCard).join('') || quiet('No open question.')) : loading);
  document.querySelectorAll('#questions textarea').forEach((t) => { if (typed[t.dataset.key]) t.value = typed[t.dataset.key]; });

  put($('queue-stats'), s.left.count ? `<span><b>${s.left.count}</b> tickets</span>
    ${s.left.seconds ? `<span><b>≈ ${Math.round(s.left.seconds / 3600)} h</b> of runs</span>` : ''}
    ${s.left.cost ? `<span><b>≈ ${dollars(s.left.cost)}</b></span>` : ''}` : '');
  put($('stuck-list'), s.stuck.length ? `<h2 class="hot">Stuck · ${s.stuck.length}</h2><div class="list stuck">${s.stuck.map(stuckRow).join('')}</div>` : '');
  put($('queue-list'), s.queued.map(ticketRow).join('') || quiet(s.github ? 'Nothing queued.' : 'Loading...'));
  put($('held-list'), s.held.length ? `<h2>On hold · ${s.held.length}</h2><div class="list">${s.held.map(heldRow).join('')}</div>` : '');
  $('parked-title').textContent = `Parked · ${s.parked.length}`;
  put($('parked-list'), s.parked.map(ticketRow).join('') || quiet('None.'));

  const code = $('login-code')?.value || '';
  put($('login-box'), loginBox(s.login));
  if (code && $('login-code')) $('login-code').value = code;
  put($('account-list'), (s.accounts.map(accountCard).join('') || quiet('No accounts in the settings.')) + addTile('account', 'Add an account'));

  put($('merged-list'), s.merged.map((m) => `<div class="row"><div class="what"><a href="${esc(m.url)}" target="_blank">${esc(m.title)}</a></div>
    <span class="when">${esc(clock(m.mergedAt))}</span></div>`).join('') || quiet('None yet.'));
  put($('run-list'), s.runs.map((r) => {
    const kind = { answered: 'answers', 'needs-rebase': 'rebase' }[r.kind] || (r.partial ? 'part' : '');
    return `<div class="row"><div class="what">${esc(r.title || `Ticket ${r.ticket}`)}
      <div class="meta">${badges([kind, r.size, modelName(r.model), r.duration && duration(r.duration), r.cost != null && `$${Number(r.cost).toFixed(2)}`])}</div></div>
      <span class="when">${ago(r.at)}</span></div>`;
  }).join('') || quiet('None yet.'));

  $('stamp').textContent = `Updated ${new Date(s.now * 1000).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}`;

  let text;
  try {
    text = info(s);
  } catch (e) {
    text = quiet('The info could not be drawn from this state. Pull down or reload to fetch a new one.');
  }
  put($('info-body'), text);
}

// Tabs: each hash shows its view. Older links and notifications name a section that a view now holds.
const viewOf = { home: 'workers', needs: 'questions', qa: 'questions', usage: 'accounts', done: 'history' };
function route() {
  const hash = location.hash.slice(1);
  const name = viewOf[hash] || hash;
  const view = $(name)?.classList.contains('view') ? name : 'workers';
  document.querySelectorAll('.view').forEach((v) => { v.hidden = v.id !== view; });
  document.querySelectorAll('#tabs a').forEach((a) => a.classList.toggle('active', a.dataset.tab === view));
}
window.addEventListener('hashchange', route);
route();

// The last state reached, kept on the device: with the PC off the app still opens on it, greyed out under a banner.
const stored = 'scriptorium-state';
function remember(snapshot) {
  try { localStorage.setItem(stored, JSON.stringify({ snapshot, at: Date.now() })); } catch (e) { /* private mode */ }
}

function recall() {
  try { return JSON.parse(localStorage.getItem(stored)); } catch (e) { return null; }
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

// Shows the last snapshot with the unconfirmed actions on top. `fetch` is the count of the fetch that brought the
// snapshot (0: no new one): an action that it confirms, or that waited too long, goes.
function draw(animate, fetch) {
  const paint = () => {
    state = structuredClone(fresh);
    for (const op of new Set(ops.values())) {
      if (op.responded && fetch > op.seq && (!op.done || op.done(state) || Date.now() > op.until)) {
        for (const [key, value] of ops) if (value === op) ops.delete(key);
        continue;
      }
      op.apply?.(state);
      if (op.responded) op.after?.(state);
    }
    render();
  };
  // A change the owner made moves smoothly from the old state to the new one; the 10 s refresh does not animate.
  if (animate && document.startViewTransition && !matchMedia('(prefers-reduced-motion: reduce)').matches) document.startViewTransition(paint);
  else paint();
}

async function refresh(animate) {
  const fetched = ++fetches;
  try {
    const response = await fetch('api/state', { cache: 'no-store', signal: AbortSignal.timeout(8000) });
    const snapshot = await response.json();
    if (!snapshot.workers) throw new Error('no state');
    fresh = snapshot;
    remember(snapshot);
    setOffline(false);
    draw(animate, fetched);
  } catch (e) {
    if (!fresh) fresh = recall()?.snapshot;
    if (fresh) draw(false, 0);
    setOffline(true);
  }
}

function toast(text) {
  const box = $('toast');
  box.textContent = text;
  box.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { box.hidden = true; }, 3500);
}

// Posts an action. `keys` are the cards it changes: the change shows at once (apply), and those cards stay busy until
// a snapshot confirms it. A refusal takes the change back and says why.
async function act(body, { keys = [], apply, after, done } = {}) {
  const op = { apply, after, done, responded: false };
  for (const key of keys) ops.set(key, op);
  if (keys.length) draw(true, 0);
  let ok = false;
  try {
    const response = await fetch('api/action', {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Queue': '1' }, body: JSON.stringify(body),
    });
    const result = await response.json();
    ok = result.ok;
    if (!ok) toast(`Failed: ${result.message}`);
  } catch (e) {
    toast('Cannot reach Scriptorium');
  }
  if (ok) Object.assign(op, { responded: true, seq: fetches, until: Date.now() + 90000 });
  else for (const key of keys) ops.delete(key);
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

// One worker more, on the account the owner picks; the server gives it the lowest free number.
async function addWorker() {
  const accounts = state.accounts || [];
  const options = accounts.map((a) => `<option value="${esc(a.name)}">${esc(a.name)}${outMark[a.status] || ''}</option>`);
  // The command-line login, offered as on a worker's card: only while no entry is that login.
  if (accounts.every((a) => a.own)) options.unshift('<option value="">command line</option>');
  const plugins = state.plugins || [];
  const values = await ask('Add a worker', 'It starts as Active. It takes tickets when its copy of the repo is made'
    + (plugins.length ? ` and its environment (${inWords(plugins.map((p) => p.title || p.name))}) is ready.` : '.'), 'Add worker', {
    fields: `<label>Account<select name="account">${options.join('')}</select></label>`,
  });
  if (values) await act({ action: 'add-worker', account: values.account || '' });
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
  if (await act({ action: 'login', account, email: values.email.trim(), new: true })) $('login-box').scrollIntoView({ block: 'nearest' });
}

// Only a disabled worker with no run goes (its ticket is free then); the dialog says what to do first.
async function removeWorker(id) {
  const worker = workerOf(state, id);
  if (!worker) return;
  const title = `Remove worker ${id}?`;
  // A disabled worker whose script is gone goes too, though its state still names a run: nothing finishes that run.
  const disabled = worker.status === 'disabled' || (worker.pending?.to === 'disabled' && worker.activity === 'down');
  if (worker.activity === 'setup') {
    await ask(title, 'Its setup still runs. When the setup has ended, remove it.');
  } else if (!disabled && worker.pending?.to === 'disabled') {
    await ask(title, 'It is disabled when its run ends. Then remove it.');
  } else if (!disabled) {
    if (await ask(title, 'Disable it first: its ticket then goes back to the queue. When it shows Disabled, remove it.', 'Disable')) setStatus(id, 'disabled');
  } else if (await ask(title, `Its script stops and its card goes. Its copy of the repo stays on the PC: a new worker ${id} uses it again.`,
    'Remove', { danger: true })) {
    await act({ action: 'remove-worker', worker: id }, {
      keys: [`worker:${id}`],
      after: (s) => { s.workers = s.workers.filter((w) => w.id !== id); },
      done: (s) => !s.workers.some((w) => w.id === id),
    });
  }
}

// Only an account nothing uses goes: its login is signed out.
async function removeAccount(name) {
  const account = accountOf(state, name);
  if (!account) return;
  const title = `Remove ${name}?`;
  if (account.uses.length) {
    const users = account.uses.map((use) => ({ frontdesk: 'the front desk', personal: 'you' }[use] || useName(use)));
    await ask(title, `${inWords(users)} ${users.length > 1 || users[0] === 'you' ? 'use' : 'uses'} it. Move ${users.length > 1 ? 'them' : 'it'} to another account first.`
      .replace(/^./, (c) => c.toUpperCase()));
    return;
  }
  if (!(await ask(title, 'Its login is signed out, and its card goes.', 'Remove', { danger: true }))) return;
  await act({ action: 'remove-account', account: name }, {
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
function sendStatus(worker, to, how) {
  const mine = (s) => s.workers.filter((w) => worker === 'all' || w.id === worker);
  return act({ action: 'status', worker, to, how }, {
    keys: mine(state).map((w) => `worker:${w.id}`),
    apply: (s) => mine(s).forEach((w) => {
      if (to !== 'active' && w.run && how !== 'now' && w.status === 'active') w.pending = { to, how };
      else Object.assign(w, { status: to, pending: null }, to === 'disabled' ? { next: null } : {});
    }),
  });
}

function setStatus(worker, to) {
  const views = worker === 'all' ? state.workers : state.workers.filter((w) => w.id === worker);
  const who = worker === 'all' ? 'all workers' : `worker ${worker}`;
  if (to === 'active' || !views.some((w) => w.run)) {
    sendStatus(worker, to, to === 'active' ? '' : 'now');
    return;
  }
  $('how-title').textContent = `${to === 'paused' ? 'Pause' : 'Disable'} ${who}`;
  $('how-options').innerHTML = Object.entries(howOptions).map(([how, [glyph, name, effect]]) => `<button data-how="${how}" data-to="${to}" data-worker="${esc(worker)}">
    ${icon(glyph)}<span><b>${name}</b><small>${effect}${how === 'finish' ? '' : ` ${keeps[to]}`}</small></span></button>`).join('');
  $('how').showModal();
}

const answerBox = (key) => document.querySelector(`#questions textarea[data-key="${CSS.escape(key)}"]`);

// An answer in text, or no text to take the default; the server decides what the queue does with it. Once the server
// said yes, the question is hidden until GitHub's next fetch drops it, so none is sent twice.
const answer = (key, text) => act({ action: 'answer', key, text }, {
  keys: [`question:${key}`],
  after: (s) => { s.questions = s.questions.filter((q) => q.key !== key); },
  done: (s) => !s.questions.some((q) => q.key === key),
});

document.addEventListener('click', async (e) => {
  // A click outside an open menu closes it.
  for (const menu of document.querySelectorAll('details.menu[open]')) if (!menu.contains(e.target)) menu.removeAttribute('open');
  const target = e.target.closest('button');
  if (!target) return;
  const data = target.dataset;
  if (data.status) {
    setStatus(data.worker, data.status);
  } else if (data.more) {
    const open = !opened.delete(data.more);
    if (open) opened.add(data.more);
    target.closest('.worker').classList.toggle('open', open);
    target.setAttribute('aria-expanded', open);
  } else if (data.take) {
    const on = target.getAttribute('aria-pressed') !== 'true';
    await act({ action: 'complexity', worker: data.worker, complexity: data.take, on }, {
      keys: [`worker:${data.worker}`],
      apply: (s) => { workerOf(s, data.worker).takes.find((t) => t.name === data.take).on = on; },
    });
  } else if (data.how) {
    $('how').close();
    await sendStatus(data.worker, data.to, data.how);
  } else if (data.force) {
    const next = state.workers.find((w) => w.id === data.force)?.next;
    if (next && !next.available && !(await ask(`Take "${next.title}" now?`,
      `The queue holds it back: ${next.why}. The run goes past the stop line and uses the room kept under it.`, 'Take it'))) return;
    await act({ action: 'force', worker: data.force }, { keys: [`worker:${data.force}`], apply: (s) => { workerOf(s, data.force).forced = true; } });
  } else if (data.unforce) {
    await act({ action: 'unforce', worker: data.unforce }, { keys: [`worker:${data.unforce}`], apply: (s) => { workerOf(s, data.unforce).forced = false; } });
  } else if (data.answer) {
    const text = answerBox(data.answer).value.trim();
    if (!text) { toast('Write an answer first'); return; }
    await answer(data.answer, text);
  } else if (data.default) {
    await answer(data.default, '');
  } else if (data.retry) {
    await act({ action: 'retry', key: data.retry }, {
      keys: [`stuck:${data.retry}`],
      after: (s) => { s.stuck = s.stuck.filter((item) => item.key !== data.retry); },
      done: (s) => !s.stuck.some((item) => item.key === data.retry),
    });
  } else if (data.login) {
    await act({ action: 'login', account: data.login }, { keys: [`account:${data.login}`] });
  } else if (data.loginCode !== undefined) {
    const code = $('login-code').value.trim();
    if (!code) { toast('Paste the code first'); return; }
    target.disabled = true;
    if (await act({ action: 'login-code', code })) $('login-code').value = '';
  } else if (data.loginCancel !== undefined) {
    if (await ask('Cancel the sign-in?', 'The account stays as it is.', 'Cancel the sign-in')) await act({ action: 'login-cancel' });
  } else if (data.ping) {
    await act({ action: 'ping', account: data.ping }, { keys: [`account:${data.ping}`] });
  } else if (data.add) {
    await (data.add === 'worker' ? addWorker() : addAccount());
  } else if (data.remove) {
    await (data.remove === 'worker' ? removeWorker(data.name) : removeAccount(data.name));
  } else if (data.steps) {
    $('steps-title').textContent = `Worker ${data.steps}: latest run`;
    $('steps-list').innerHTML = '<li>Loading...</li>';
    $('steps').showModal();
    try {
      const log = await (await fetch(`api/log?worker=${encodeURIComponent(data.steps)}`, { cache: 'no-store' })).json();
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
  if (data.assign) {
    e.target.blur();
    const account = e.target.value;
    await act({ action: 'assign', worker: data.assign, account }, { keys: [`worker:${data.assign}`], apply: (s) => { workerOf(s, data.assign).account = account; } });
  } else if (data.priority) {
    e.target.blur();
    // GitHub holds the priority: the row stays busy until the next fetch shows it.
    const number = Number(data.priority);
    const priority = e.target.value;
    await act({ action: 'priority', number, priority }, {
      keys: [`ticket:${number}`],
      apply: (s) => { const row = rowOf(s, number); if (row) row.priority = priority === 'park' ? '' : priority; },
      done: (s) => (rowOf(s, number)?.priority || 'park') === priority,
    });
  } else if (data.stop) {
    e.target.blur();
    const value = e.target.value / 100;
    await act({ action: 'stop-at', account: data.stop, window: data.window, value }, {
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
    await act({ action: 'pick-up', account: data.account, window: data.window, size: data.pick, value }, {
      keys: [`account:${data.account}`],
      apply: (s) => { accountOf(s, data.account)[data.window].pickUp[data.pick] = value; },
    });
  } else if (data.compact !== undefined) {
    e.target.blur();
    const value = Math.round(Number(e.target.value)) * 1000 + COMPACT_BUFFER;
    if (!(value >= 100000 && value <= 1000000)) {
      toast(`Between ${e.target.min}k and ${e.target.max}k tokens`);
      e.target.value = Math.round((state.compactWindow - COMPACT_BUFFER) / 1000);
      return;
    }
    await act({ action: 'compact-window', value }, {
      keys: ['compact'],
      apply: (s) => {
        // A complexity with a window of its own keeps it.
        for (const c of s.complexities || []) if (c.compactWindow === s.compactWindow) c.compactWindow = value;
        s.compactWindow = value;
      },
      done: (s) => s.compactWindow === value,
    });
  } else if (data.guard) {
    e.target.blur();
    const value = e.target.value / 100;
    await act({ action: 'keep', use: data.guard, value }, {
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
fresh = recall()?.snapshot;
if (fresh) draw(false, 0);
refresh();
if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});
