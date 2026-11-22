const shell = document.querySelector('#garage');
const content = document.querySelector('#content');
const title = document.querySelector('#title');
const subtitle = document.querySelector('#subtitle');
const back = document.querySelector('#back');
const escapeLabel = document.querySelector('#escape-label');
const lookCard = document.querySelector('#vehicle-look');
const lookModel = document.querySelector('#look-model');
const lookMake = document.querySelector('#look-make');
const lookPlate = document.querySelector('#look-plate');
const lookDetails = document.querySelector('#look-details');

let current = null;
let buttons = new Map();
let selected = null;
let summary = null;
let lookMotion = null;
let texts = {};

const colorVariables = {
    accent: '--accent', selected: '--accent-bg', background: '--surface', card: '--card',
    border: '--line', text: '--ink', muted: '--muted', success: '--green', danger: '--danger'
};

function t(text) {
    return Object.prototype.hasOwnProperty.call(texts, text) ? texts[text] : text;
}

function applySettings({ colors, language, texts: translated }) {
    texts = translated || {};
    document.documentElement.lang = language || 'de';
    for (const [name, property] of Object.entries(colorVariables)) {
        const color = colors?.[name];
        if (typeof color === 'string' && /^#[a-f\d]{6}$/i.test(color)) {
            document.documentElement.style.setProperty(property, color);
        }
    }
    document.querySelectorAll('[data-text]').forEach(node => { node.textContent = t(node.dataset.text); });
    lookCard.setAttribute('aria-label', t('Fahrzeugdaten'));
    if (current) render(current);
    else {
        back.setAttribute('aria-label', t('Schließen'));
        escapeLabel.textContent = t('Schließen');
    }
}

const sectionNames = {
    garage_entrance: 'Eingang',
    vehicle_details: 'Fahrzeugdetails',
    vehicle_preview: '3D-Vorschau',
    interior_vehicle_info: 'Fahrzeugdaten',
    assign_slot: 'Stellplatz',
    slot_station: 'Innenraum',
    garage_admin: 'Verwaltung',
    garage_admin_choice: 'Verwaltung',
    society_models: 'Fuhrpark'
};

function element(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
}

function send(action, payload = {}) {
    if (typeof GetParentResourceName !== 'function') return;
    return fetch(`https://${GetParentResourceName()}/${action}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    });
}

function sendAction(action, payload) {
    send(action, payload)?.catch((error) => console.error('DaGarage UI:', error));
}

function goBack() {
    if (current) sendAction('back', { id: current.id });
}

function actionable(item) {
    return item.value !== undefined && item.value !== null && item.value !== 'info' && !item.disabled;
}

function select(index, scroll = false) {
    const next = buttons.get(index);
    if (!next) return;
    const previous = buttons.get(selected);
    if (previous) previous.dataset.selected = 'false';
    selected = index;
    next.dataset.selected = 'true';
    const item = current.data.elements[index - 1];
    if (summary && item.plate !== undefined) showSummary(item);
    if (scroll) next.scrollIntoView({ block: 'nearest' });
}

function choose(index) {
    if (!current || !buttons.has(index)) return;
    select(index);
    sendAction('choose', { id: current.id, index });
}

function button(index, item, style) {
    const node = element('button', style);
    node.type = 'button';
    node.disabled = !!item.disabled;
    if (item.disabled) return node;
    node.addEventListener('click', () => choose(index));
    node.addEventListener('focus', () => select(index));
    buttons.set(index, node);
    return node;
}

function actionRow(index, item) {
    const node = button(index, item, item.value === 'delete' ? 'action-row danger' : 'action-row');
    node.append(element('span', '', item.label), element('span', 'arrow', '›'));
    return node;
}

function entrance(items) {
    const grid = element('div', 'entrance-grid');
    items.forEach((item, index) => {
        const card = button(index + 1, item, 'entrance-card');
        const mark = element('span', 'action-mark', item.value === 'enter' ? '▤' : item.value === 'inside' ? '▦' : '≡');
        mark.setAttribute('aria-hidden', 'true');
        const arrow = element('span', 'arrow', '↗');
        arrow.setAttribute('aria-hidden', 'true');
        card.append(mark, element('strong', '', item.label), element('small', '', item.description), arrow);
        grid.append(card);
    });
    content.append(grid);
}

function vehicleRow(index, item) {
    const node = button(index, item, 'vehicle-row');
    const info = element('span');
    const name = element('strong', 'vehicle-name');
    if (item.favorite) {
        const star = element('span', 'favorite', '★');
        star.setAttribute('aria-label', t('Favorit'));
        name.append(star);
    }
    name.append(document.createTextNode(item.label));
    info.append(name, element('span', 'row-plate', item.plate));
    const state = element('span', 'row-state', item.status);
    state.dataset.status = item.statusCode;
    node.append(info, state, element('span', 'arrow', '›'));
    node.addEventListener('pointerenter', () => select(index));
    return node;
}

function metric(label, value) {
    const row = element('div', 'metric');
    row.append(element('span', '', label), element('strong', '', value));
    return row;
}

function showSummary(item) {
    const identity = element('div');
    const badge = element('span', 'summary-state', item.status);
    badge.dataset.status = item.statusCode;
    identity.append(badge, element('h2', '', item.label), element('span', 'number-plate', item.plate));
    const stats = element('div', 'metrics');
    stats.append(metric(t(item.fuelSaved ? 'Tankstand (gesp.)' : 'Tankstand'), item.fuel));
    if (typeof item.fuelValue === 'number' && Number.isFinite(item.fuelValue)) {
        const gauge = element('div', 'gauge');
        const fill = element('span');
        gauge.setAttribute('aria-hidden', 'true');
        fill.style.width = `${Math.min(100, Math.max(0, item.fuelValue))}%`;
        gauge.append(fill);
        stats.append(gauge);
    }
    const condition = item.conditionSaved ? ' ' + t('(gesp.)') : '';
    stats.append(metric(t('Motor') + condition, item.engine), metric(t('Karosserie') + condition, item.body));
    if (item.warning) stats.append(element('p', 'warning', item.warning));
    summary.replaceChildren(identity, stats);
}

function vehicles(items) {
    const layout = element('div', 'vehicle-layout');
    const left = element('div', 'list-side');
    const list = element('div', 'vehicle-list');
    const secondary = element('div', 'secondary');
    const rows = items.filter((item) => item.plate !== undefined);
    const caption = element('div', 'list-caption');
    caption.append(element('span', '', t('Fahrzeuge')), element('span', '', rows.length));
    left.append(caption, list);
    items.forEach((item, index) => {
        if (item.plate !== undefined) list.append(vehicleRow(index + 1, item));
        else if (actionable(item)) secondary.append(actionRow(index + 1, item));
        else list.append(element('p', 'empty', item.label));
    });
    if (secondary.childElementCount) left.append(secondary);
    layout.append(left);
    if (rows.length) {
        summary = element('aside', 'summary');
        summary.setAttribute('aria-label', t('Ausgewähltes Fahrzeug'));
        layout.append(summary);
        showSummary(rows[0]);
    }
    content.append(layout);
}

function settings(items) {
    const actions = element('div', 'actions');
    const facts = element('dl', 'facts');
    items.forEach((item, index) => {
        if (actionable(item)) {
            actions.append(actionRow(index + 1, item));
            return;
        }
        const divider = item.label.indexOf(' · ');
        const row = element('div', divider < 0 ? 'fact full' : 'fact');
        row.append(element('dt', '', divider < 0 ? item.label : item.label.slice(0, divider)));
        if (divider >= 0) row.append(element('dd', '', item.label.slice(divider + 3)));
        facts.append(row);
    });
    if (actions.childElementCount) content.append(actions);
    if (facts.childElementCount) content.append(facts);
}

function render(menu) {
    current = menu || null;
    shell.hidden = !current;
    if (!current) return;
    hideLook();
    buttons = new Map();
    selected = null;
    summary = null;
    content.replaceChildren();
    const data = current.data;
    const layout = current.name === 'vehicle_preview' ? 'preview' : data.layout || 'menu';
    shell.dataset.layout = layout;
    title.textContent = data.title;
    subtitle.textContent = data.subtitle || t(sectionNames[current.name] || '');
    const closeLabel = t(current.nested ? 'Zurück' : 'Schließen');
    escapeLabel.textContent = closeLabel;
    back.setAttribute('aria-label', closeLabel);
    back.textContent = current.nested ? '‹' : '×';
    const items = Array.isArray(data.elements) ? data.elements : [];
    if (layout === 'entrance') entrance(items);
    else if (layout === 'vehicles') vehicles(items);
    else settings(items);
    select(buttons.has(current.selection) ? current.selection : buttons.keys().next().value, true);
}

function hideLook() {
    if (lookMotion?.frame) cancelAnimationFrame(lookMotion.frame);
    lookMotion = null;
    lookCard.hidden = true;
}

function placeLook(x, y) {
    lookCard.style.transform = `translate3d(${x}px, ${y}px, 0) translate(-50%, calc(-100% - .6rem))`;
}

function animateLook(time) {
    const motion = lookMotion;
    if (!motion) return;
    const elapsed = Math.min(48, Math.max(0, time - motion.time));
    motion.time = time;
    const weight = 1 - Math.exp(-elapsed / 34);
    motion.x += (motion.targetX - motion.x) * weight;
    motion.y += (motion.targetY - motion.y) * weight;
    const settled = Math.abs(motion.targetX - motion.x) < 0.35 && Math.abs(motion.targetY - motion.y) < 0.35;
    if (settled) {
        motion.x = motion.targetX;
        motion.y = motion.targetY;
        motion.frame = 0;
    } else {
        motion.frame = requestAnimationFrame(animateLook);
    }
    placeLook(motion.x, motion.y);
}

function updateLookTarget(motion, x, y) {
    motion.screenX = x;
    motion.screenY = y;
    const margin = motion.width / 2 + 8;
    motion.targetX = Math.min(innerWidth - margin, Math.max(margin, x * innerWidth));
    motion.targetY = Math.min(innerHeight, Math.max(motion.height + 16, y * innerHeight));
}

function renderLook({ id, vehicle, x, y }) {
    if (current || vehicle === false) return hideLook();
    if (!Number.isFinite(x) || !Number.isFinite(y)) return;
    if (vehicle) {
        hideLook();
        lookModel.textContent = vehicle.model;
        lookMake.textContent = vehicle.make;
        lookPlate.textContent = vehicle.plate;
        lookDetails.textContent = [
            `${t('Stellplatz')} ${vehicle.slot}`,
            vehicle.class,
            vehicle.fuelType ? `${t('Kraftstoff')}: ${vehicle.fuelType}` : null
        ].filter(Boolean).join(' · ');
        lookCard.hidden = false;
        lookMotion = { id, width: lookCard.offsetWidth, height: lookCard.offsetHeight, frame: 0 };
        updateLookTarget(lookMotion, x, y);
        lookMotion.x = lookMotion.targetX;
        lookMotion.y = lookMotion.targetY;
        placeLook(lookMotion.x, lookMotion.y);
        return;
    }
    const motion = lookMotion;
    if (!motion || motion.id !== id) return;
    updateLookTarget(motion, x, y);
    if (!motion.frame) {
        motion.time = performance.now();
        motion.frame = requestAnimationFrame(animateLook);
    }
}

window.addEventListener('resize', () => {
    if (!lookMotion) return;
    lookMotion.width = lookCard.offsetWidth;
    lookMotion.height = lookCard.offsetHeight;
    renderLook({ id: lookMotion.id, x: lookMotion.screenX, y: lookMotion.screenY });
});

back.addEventListener('click', goBack);
window.addEventListener('message', ({ data }) => {
    if (data?.type === 'dagarage:settings') applySettings(data);
    else if (data?.type === 'dagarage:menu') render(data.menu);
    else if (data?.type === 'dagarage:look') renderLook(data);
});
document.addEventListener('keydown', (event) => {
    if (!current) return;
    if (event.key === 'Escape' || event.key === 'Backspace') {
        event.preventDefault();
        if (!event.repeat) goBack();
    } else if (event.key === 'Enter' && event.target !== back) {
        event.preventDefault();
        if (!event.repeat) choose(selected);
    } else if (event.key === 'ArrowDown' || event.key === 'ArrowUp') {
        event.preventDefault();
        const indexes = Array.from(buttons.keys());
        if (!indexes.length) return;
        const direction = event.key === 'ArrowDown' ? 1 : -1;
        const position = (indexes.indexOf(selected) + direction + indexes.length) % indexes.length;
        select(indexes[position], true);
    }
});
function announce(attempt = 0) {
    const request = send('ready');
    if (!request) return;
    const retry = () => {
        if (attempt < 8) setTimeout(() => announce(attempt + 1), 350);
    };
    request.then((response) => { if (!response.ok) retry(); }, retry);
}

announce();
