// Her wheel: a ring of sectors around her head, for the things you do most (talk, status, report,
// the satellite, how she answers, put her away, teleport, the whole menu). Middle-click on her, or
// hold her still for a moment (capri.js); hover a sector, click it; Esc, a click elsewhere, or the
// pointer wandering off closes it. Drawn as SVG so the sectors have her bevelled, glitchy look.

import { reducedMotion } from './util.js';

const INNER = 38;  // the hole her head shows through (viewBox units)
const OUTER = 96;
const GAP = 2.2;   // degrees between sectors
const LEAVE = 46;  // px past the ring before it closes on its own

export class Wheel {
  constructor({ root, capri }) {
    this.root = root;     // <div id="wheel">
    this.capri = capri;
    this.items = [];      // [{ id, icon, label, hot }], as last opened
    this.onPick = null;   // (id) => void
    this.onClose = null;  // () => void
    this.center = { x: 0, y: 0 };
    this.size = 240;      // px across
    this.open = false;
    this.hover = null;
    this.svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    this.svg.setAttribute('viewBox', '-100 -100 200 200');
    this.svg.classList.add('wheel__ring');
    this.root.append(this.svg);
    this.root.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      this.close();
    });
    window.addEventListener('keydown', (e) => {
      if (this.open && e.key === 'Escape') this.close();
    });
    window.addEventListener('mousedown', (e) => {
      if (this.open && !this.root.contains(e.target)) this.close();
    });
    window.addEventListener('mousemove', (e) => {
      if (!this.open) return;
      const d = Math.hypot(e.clientX - this.center.x, e.clientY - this.center.y);
      if (d > this.size / 2 + LEAVE) this.close(); // wandered off
    });
  }

  get visible() {
    return this.open;
  }

  // Open around her head with these items; a sector's `hot` draws it in her accent colour.
  show(items, at) {
    this.items = items;
    this.size = Math.round(256 * Math.max(0.85, Math.min(1.35, this.capri.scale / 0.6)));
    this.render();
    this.open = true;
    this.root.hidden = false;
    this.root.style.width = this.root.style.height = `${this.size}px`;
    this.follow(at);
    this.root.classList.remove('is-entering');
    void this.root.offsetWidth;
    if (!reducedMotion.matches) this.root.classList.add('is-entering');
  }

  close() {
    if (!this.open) return;
    this.open = false;
    this.hover = null;
    this.root.hidden = true;
    this.onClose?.();
  }

  // Centred on her head, kept on screen; she bobs, so this follows her every drawing.
  follow(at) {
    if (!this.open || !at) return;
    const half = this.size / 2;
    const x = Math.min(Math.max(at.x, half + 8), innerWidth - half - 8);
    const y = Math.min(Math.max(at.y, half + 8), innerHeight - half - 8);
    this.center = { x, y };
    this.root.style.left = `${Math.round(x - half)}px`;
    this.root.style.top = `${Math.round(y - half)}px`;
  }

  // The pointer is over the ring (the hole in the middle is hers, not the wheel's).
  hit(x, y) {
    if (!this.open) return false;
    const d = Math.hypot(x - this.center.x, y - this.center.y) / (this.size / 200);
    return d >= INNER - 6 && d <= OUTER + 6;
  }

  render() {
    const svg = this.svg;
    svg.replaceChildren();
    const n = this.items.length;
    if (!n) return;
    const step = 360 / n;
    const ns = 'http://www.w3.org/2000/svg';
    const el = (tag, attrs = {}) => {
      const node = document.createElementNS(ns, tag);
      for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
      return node;
    };
    // a faint full ring behind, like a reticle
    svg.append(el('circle', { class: 'wheel__halo', r: OUTER + 2 }));
    svg.append(el('circle', { class: 'wheel__halo', r: INNER - 4 }));
    this.items.forEach((item, i) => {
      const a0 = -90 - step / 2 + i * step + GAP / 2; // the first sector straight up
      const a1 = a0 + step - GAP;
      const g = el('g', { class: `wheel__sector${item.hot ? ' is-hot' : ''}`, 'data-id': item.id });
      g.append(el('path', { class: 'wheel__slice', d: sector(a0, a1) }));
      const mid = ((a0 + a1) / 2) * Math.PI / 180;
      const r = (INNER + OUTER) / 2;
      const cx = Math.cos(mid) * r;
      const cy = Math.sin(mid) * r;
      const icon = el('text', { class: 'wheel__icon', x: cx, y: cy - 7, 'text-anchor': 'middle' });
      icon.textContent = item.icon;
      // a long word (Поговорить, Teletransporte) is set smaller, so it stays inside its sector
      const chars = [...item.label].length;
      const label = el('text', { class: `wheel__label${chars > 10 ? ' is-l3' : chars > 8 ? ' is-l2' : chars > 6 ? ' is-l1' : ''}`, x: cx, y: cy + 10, 'text-anchor': 'middle' });
      label.textContent = item.label;
      g.append(icon, label);
      g.addEventListener('mouseenter', () => { this.hover = item.id; g.classList.add('is-hover'); });
      g.addEventListener('mouseleave', () => { this.hover = null; g.classList.remove('is-hover'); });
      g.addEventListener('click', (e) => {
        e.stopPropagation();
        const id = item.id;
        this.close();
        this.onPick?.(id);
      });
      svg.append(g);
    });
  }
}

// An annular sector from angle a0 to a1 (degrees), with bevelled corners like her panel's.
function sector(a0, a1) {
  const p = (r, a) => {
    const t = a * Math.PI / 180;
    return `${(Math.cos(t) * r).toFixed(2)} ${(Math.sin(t) * r).toFixed(2)}`;
  };
  const large = a1 - a0 > 180 ? 1 : 0;
  return [
    `M ${p(INNER, a0)}`,
    `L ${p(OUTER - 5, a0)}`,
    `L ${p(OUTER, a0 + 2.5)}`,
    `A ${OUTER} ${OUTER} 0 ${large} 1 ${p(OUTER, a1 - 2.5)}`,
    `L ${p(OUTER - 5, a1)}`,
    `L ${p(INNER, a1)}`,
    `A ${INNER} ${INNER} 0 ${large} 0 ${p(INNER, a0)}`,
    'Z',
  ].join(' ');
}
