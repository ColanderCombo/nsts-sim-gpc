import {LitElement, html, css, nothing} from 'lit';
import {customElement, property, state} from 'lit/decorators.js';
import {keyed} from 'lit/directives/keyed.js';
import './split-pane';

/**
 * dock.ts — a flexible multi-pane "editor" docking system.
 *
 * The layout is a binary tree of nodes:
 *   - SplitNode: two children separated by a draggable divider
 *   - LeafNode:  a tabbed pane holding one or more editor instances
 *
 * Plus a flat list of FloatPanel overlays (in-app floating windows).
 *
 * <dock-root> owns the whole layout, the editor-element instances, and
 * persistence.  <dock-pane> renders one leaf (tab strip + active editor +
 * the active editor's hoisted toolbar).
 *
 * The system is domain-agnostic.  The host supplies a DockHost describing
 * the available editor types and how to wire a freshly-created element:
 *
 *   const root = document.createElement('dock-root') as DockRoot;
 *   root.host = {
 *     editors: [ { id:'disasm', title:'Disassembly', create:() => <gpc-disasm> }, ... ],
 *     onMount: (el, id) => wire(el),          // called once per element
 *     defaultLayout: () => ({...}),           // used when nothing persisted
 *     storageKey: 'gpc-dock-layout',
 *   };
 *
 * An editor element MAY implement `getToolbar(): HTMLElement | null` to have
 * its controls hoisted into the tab strip next to its tab.
 */

// ----------------------------------------------------------------------
// Layout model
// ----------------------------------------------------------------------

export interface TabState {
  iid: string;        // unique instance id (stable across saves)
  editorId: string;   // registry id
}

export interface LeafNode {
  type: 'leaf';
  id: string;
  tabs: TabState[];
  active: number;     // index into tabs
}

export interface SplitNode {
  type: 'split';
  id: string;
  dir: 'h' | 'v';     // h = left|right, v = top|bottom
  size: number;       // px size of the SECOND child
  a: DockNode;
  b: DockNode;
}

export type DockNode = LeafNode | SplitNode;

export type DropZone = 'left' | 'right' | 'top' | 'bottom' | 'center';

export interface FloatPanel {
  id: string;
  node: LeafNode;
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface Layout {
  root: DockNode;
  floats: FloatPanel[];
}

export interface EditorDef {
  id: string;
  title: string;
  singleton?: boolean;
  create: () => HTMLElement;
}

export interface DockHost {
  editors: EditorDef[];
  onMount?: (el: HTMLElement, editorId: string) => void;
  defaultLayout: () => Layout;
  storageKey?: string;
}

export interface DockableEditor extends HTMLElement {
  getToolbar?(): HTMLElement | null;
}

// ----------------------------------------------------------------------
// id helpers — no Math.random reliance for determinism is unnecessary here,
// but we keep a monotonic counter so ids are unique within a session.
// ----------------------------------------------------------------------

let _idCounter = 1;
function newId(prefix: string): string {
  return `${prefix}${_idCounter++}`;
}

// ----------------------------------------------------------------------
// Shared context-menu helper (rendered into document.body, theme-matched)
// ----------------------------------------------------------------------

export interface MenuItem {
  label?: string;
  disabled?: boolean;
  action?: () => void;
  submenu?: MenuItem[];
  separator?: boolean;
}

function showMenu(x: number, y: number, items: MenuItem[]): void {
  document.getElementById('dock-context-menu')?.remove();

  const menu = buildMenu(items);
  menu.id = 'dock-context-menu';
  menu.style.left = `${x}px`;
  menu.style.top = `${y}px`;
  document.body.appendChild(menu);

  const close = (ev: MouseEvent) => {
    if (!menu.contains(ev.target as Node)) {
      menu.remove();
      document.removeEventListener('mousedown', close, true);
    }
  };
  setTimeout(() => document.addEventListener('mousedown', close, true), 0);
}

function buildMenu(items: MenuItem[]): HTMLDivElement {
  const menu = document.createElement('div');
  menu.className = 'dock-menu';
  menu.style.cssText =
    "position: fixed; z-index: 100000; background: #2b2b2b; border: 1px solid #555;" +
    " padding: 2px 0; min-width: 150px; font-family: 'Consolas for Powerline', Consolas, monospace;" +
    " font-size: 11px; box-shadow: 2px 2px 6px rgba(0,0,0,0.5);";

  for (const it of items) {
    if (it.separator) {
      const sep = document.createElement('div');
      sep.style.cssText = 'height: 0; margin: 3px 6px; border-top: 1px solid #444;';
      menu.appendChild(sep);
      continue;
    }
    const row = document.createElement('div');
    const hasSub = !!(it.submenu && it.submenu.length);
    row.textContent = (it.label ?? '') + (hasSub ? '  ▸' : '');
    row.style.cssText =
      `padding: 3px 14px; white-space: nowrap; position: relative;` +
      (it.disabled
        ? ' color: #666; cursor: default;'
        : ' color: #ddd; cursor: pointer;');

    if (!it.disabled) {
      let sub: HTMLDivElement | null = null;
      const openSub = () => {
        if (!hasSub || sub) return;
        sub = buildMenu(it.submenu!);
        sub.style.position = 'fixed';
        const r = row.getBoundingClientRect();
        sub.style.left = `${r.right - 2}px`;
        sub.style.top = `${r.top}px`;
        document.body.appendChild(sub);
      };
      const closeSub = () => { sub?.remove(); sub = null; };

      row.onmouseenter = () => {
        row.style.backgroundColor = '#1565a0';
        openSub();
      };
      row.onmouseleave = (ev: MouseEvent) => {
        row.style.backgroundColor = '';
        // keep submenu open if pointer moved into it
        if (sub && (ev.relatedTarget instanceof Node) && sub.contains(ev.relatedTarget)) return;
        closeSub();
      };
      if (!hasSub && it.action) {
        row.onclick = (ev) => {
          ev.stopPropagation();
          document.getElementById('dock-context-menu')?.remove();
          closeSub();
          it.action!();
        };
      }
    }
    menu.appendChild(row);
  }
  return menu;
}

// ----------------------------------------------------------------------
// <dock-pane> — one leaf: tab strip + hoisted toolbar + active editor body
// ----------------------------------------------------------------------

@customElement('dock-pane')
export class DockPane extends LitElement {

  root!: DockRoot;
  node!: LeafNode;
  // Bumped by the root on every layout mutation so Lit re-runs updated().
  @property({ type: Number }) declare rev: number;
  // True when this pane lives inside a floating panel (disables some ops).
  @property({ type: Boolean }) declare floating: boolean;

  private _body: HTMLDivElement | null = null;
  private _toolbarHost: HTMLDivElement | null = null;
  private _dragIid: string | null = null;
  private _dragStart = { x: 0, y: 0 };

  constructor() {
    super();
    this.rev = 0;
    this.floating = false;
  }

  connectedCallback(): void {
    super.connectedCallback();
    this.root?._registerPane(this);
  }

  disconnectedCallback(): void {
    super.disconnectedCallback();
    this.root?._unregisterPane(this);
  }

  firstUpdated(): void {
    this._body = this.shadowRoot!.getElementById('body') as HTMLDivElement;
    this._toolbarHost = this.shadowRoot!.getElementById('toolbarhost') as HTMLDivElement;
    this._reconcile();
  }

  updated(): void {
    this._reconcile();
  }

  // Mount the active editor element into the body, hide the rest, and hoist
  // the active editor's toolbar into the tab strip.
  private _reconcile(): void {
    if (!this._body || !this.node) return;
    const tabs = this.node.tabs;
    const activeTab = tabs[this.node.active];

    // Mount/show editor elements belonging to this leaf.
    const want = new Set(tabs.map(t => t.iid));
    for (const tab of tabs) {
      const el = this.root.getEl(tab.iid);
      if (!el) continue;
      if (el.parentElement !== this._body) this._body.appendChild(el);
      el.style.display = tab === activeTab ? '' : 'none';
    }
    // Remove any element that no longer belongs here (moved/floated away).
    for (const child of Array.from(this._body.children)) {
      const iid = (child as HTMLElement).dataset.iid;
      if (!iid || !want.has(iid)) {
        if ((child as HTMLElement).dataset.iid) this._body.removeChild(child);
      }
    }

    // Hoist the active editor's toolbar.
    if (this._toolbarHost) {
      this._toolbarHost.replaceChildren();
      if (activeTab) {
        const el = this.root.getEl(activeTab.iid) as DockableEditor | null;
        const tb = el?.getToolbar?.();
        if (tb) this._toolbarHost.appendChild(tb);
      }
    }

    // Let the freshly-shown editor recompute its layout.
    if (activeTab) (this.root.getEl(activeTab.iid) as any)?.refresh?.();
  }

  // --- tab interactions ---

  private _selectTab(i: number): void {
    if (this.node.active === i) return;
    this.node.active = i;
    this.root._touch();
  }

  private _tabMenu(ev: MouseEvent, tab: TabState): void {
    ev.preventDefault();
    ev.stopPropagation();
    const def = this.root._def(tab.editorId);
    showMenu(ev.clientX, ev.clientY, [
      { label: `Remove ${def?.title ?? tab.editorId}`, action: () => this.root.removeTab(this.node, tab.iid) },
      { label: 'Float editor', action: () => this.root.floatEditor(this.node, tab.iid, ev.clientX, ev.clientY) },
    ]);
  }

  private _paneMenu(ev: MouseEvent): void {
    ev.preventDefault();
    ev.stopPropagation();
    this.root._showPaneMenu(this.node, ev.clientX, ev.clientY, this.floating);
  }

  // --- manual tab drag (move between panes / float out) ---

  private _tabMouseDown(ev: MouseEvent, tab: TabState): void {
    if (ev.button !== 0) return;
    this._dragIid = tab.iid;
    this._dragStart = { x: ev.clientX, y: ev.clientY };
    document.addEventListener('mousemove', this._onDragMove, true);
    document.addEventListener('mouseup', this._onDragUp, true);
  }

  private _dragging = false;
  private _ghost: HTMLDivElement | null = null;

  private _onDragMove = (ev: MouseEvent): void => {
    if (!this._dragIid) return;
    const dx = ev.clientX - this._dragStart.x;
    const dy = ev.clientY - this._dragStart.y;
    if (!this._dragging && Math.hypot(dx, dy) < 5) return;
    this._dragging = true;
    if (!this._ghost) {
      const tab = this.node.tabs.find(t => t.iid === this._dragIid);
      const def = tab ? this.root._def(tab.editorId) : null;
      this._ghost = document.createElement('div');
      this._ghost.textContent = def?.title ?? '';
      this._ghost.style.cssText =
        "position: fixed; z-index: 100001; pointer-events: none; padding: 2px 8px;" +
        " background: #1565a0; color: #fff; font: 11px 'Consolas for Powerline', Consolas, monospace;" +
        " border: 1px solid #3b8; opacity: 0.9;";
      document.body.appendChild(this._ghost);
    }
    this._ghost.style.left = `${ev.clientX + 8}px`;
    this._ghost.style.top = `${ev.clientY + 8}px`;

    // Highlight the drop zone under the pointer (split edge or center).
    const target = this.root._paneAt(ev.clientX, ev.clientY);
    if (target) {
      this.root._showDropHint(target, this.root._zoneFor(target, ev.clientX, ev.clientY));
    } else {
      this.root._hideDropHint();
    }
  };

  private _onDragUp = (ev: MouseEvent): void => {
    document.removeEventListener('mousemove', this._onDragMove, true);
    document.removeEventListener('mouseup', this._onDragUp, true);
    this._ghost?.remove();
    this._ghost = null;
    this.root._hideDropHint();
    const iid = this._dragIid;
    const wasDragging = this._dragging;
    this._dragIid = null;
    this._dragging = false;
    if (!iid || !wasDragging) return;

    const target = this.root._paneAt(ev.clientX, ev.clientY);
    if (target) {
      const zone = this.root._zoneFor(target, ev.clientX, ev.clientY);
      this.root.dropEditor(this.node, iid, target.node, zone, target.getBoundingClientRect());
    } else {
      // Dropped outside any pane → float it.
      this.root.floatEditor(this.node, iid, ev.clientX, ev.clientY);
    }
  };

  render() {
    const tabs = this.node?.tabs ?? [];
    return html`
      <div id="strip" @contextmenu="${this._paneMenu}">
        ${tabs.map((tab, i) => {
          const def = this.root?._def(tab.editorId);
          return html`<div
            class="tab ${i === this.node.active ? 'active' : ''}"
            @mousedown="${(e: MouseEvent) => this._tabMouseDown(e, tab)}"
            @click="${() => this._selectTab(i)}"
            @contextmenu="${(e: MouseEvent) => this._tabMenu(e, tab)}"
            title="${def?.title ?? tab.editorId}"
          >${def?.title ?? tab.editorId}</div>`;
        })}
        <div id="toolbarhost"></div>
        <div id="spacer" @contextmenu="${this._paneMenu}"></div>
      </div>
      <div id="body" @contextmenu="${(e: MouseEvent) => { if (tabs.length === 0) this._paneMenu(e); }}"></div>
      ${tabs.length === 0
        ? html`<div id="empty" @contextmenu="${this._paneMenu}">empty pane — right-click to add an editor</div>`
        : nothing}
    `;
  }

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      flex: 1;
      min-height: 0;
      min-width: 0;
      overflow: hidden;
      background: #111;
      position: relative;
    }
    #strip {
      display: flex;
      align-items: stretch;
      flex: 0 0 auto;
      background: #1a1a1a;
      border-bottom: 1px solid #333;
      min-height: 22px;
      overflow: hidden;
    }
    .tab {
      display: flex;
      align-items: center;
      padding: 2px 10px;
      font: 10px 'Consolas for Powerline', Consolas, monospace;
      color: #999;
      background: #1a1a1a;
      border-right: 1px solid #333;
      cursor: pointer;
      white-space: nowrap;
      user-select: none;
    }
    .tab:hover { background: #242424; color: #ccc; }
    .tab.active {
      color: #fff;
      background: #111;
      border-bottom: 2px solid #f80;
    }
    #toolbarhost {
      display: flex;
      align-items: center;
      flex: 0 0 auto;
      margin-left: 6px;
    }
    #spacer { flex: 1 1 auto; min-width: 8px; }
    #body {
      flex: 1;
      min-height: 0;
      min-width: 0;
      display: flex;
      overflow: hidden;
      position: relative;
    }
    #body > ::slotted(*) { flex: 1; }
    #empty {
      position: absolute;
      inset: 22px 0 0 0;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #555;
      font: 11px 'Consolas for Powerline', Consolas, monospace;
      user-select: none;
      pointer-events: auto;
    }
  `;
}

// ----------------------------------------------------------------------
// <dock-root> — owns the layout tree, editor instances, and persistence.
// ----------------------------------------------------------------------

@customElement('dock-root')
export class DockRoot extends LitElement {

  @state() private declare _layout: Layout;
  @state() private declare _rev: number;

  private _host: DockHost | null = null;
  private _els = new Map<string, HTMLElement>();  // iid -> editor element
  private _panes = new Set<DockPane>();

  constructor() {
    super();
    this._layout = { root: { type: 'leaf', id: newId('L'), tabs: [], active: 0 }, floats: [] };
    this._rev = 0;
  }

  set host(h: DockHost) {
    this._host = h;
    this._load();
  }
  get host(): DockHost { return this._host!; }

  // --- registry helpers ---

  _def(editorId: string): EditorDef | undefined {
    return this._host?.editors.find(e => e.id === editorId);
  }

  getEl(iid: string): HTMLElement | null {
    return this._els.get(iid) ?? null;
  }

  // All live editor elements (for the host's updateDisplay loop).
  allEditors(): HTMLElement[] {
    return Array.from(this._els.values());
  }

  // Live editor elements of a given registry id (for directed events).
  editorsOf(editorId: string): HTMLElement[] {
    const out: HTMLElement[] = [];
    this._eachTab((tab) => {
      if (tab.editorId === editorId) {
        const el = this._els.get(tab.iid);
        if (el) out.push(el);
      }
    });
    return out;
  }

  // --- pane registry (for hit-testing during drag) ---

  _registerPane(p: DockPane): void { this._panes.add(p); }
  _unregisterPane(p: DockPane): void { this._panes.delete(p); }

  _paneAt(x: number, y: number): DockPane | null {
    for (const p of this._panes) {
      const r = p.getBoundingClientRect();
      if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return p;
    }
    return null;
  }

  // --- drag-and-drop zones + highlight ---

  // Which region of `pane` the pointer is over: an edge (split there) or the
  // center (drop as a tab).  Floating panes only accept center (leaf-only).
  _zoneFor(pane: DockPane, x: number, y: number): DropZone {
    const r = pane.getBoundingClientRect();
    if (pane.floating || r.width === 0 || r.height === 0) return 'center';
    const fx = (x - r.left) / r.width;
    const fy = (y - r.top) / r.height;
    const edge = 0.28; // fraction of the pane treated as an edge zone
    const dist = { left: fx, right: 1 - fx, top: fy, bottom: 1 - fy };
    let zone: DropZone = 'center';
    let min = edge;
    (Object.keys(dist) as Array<keyof typeof dist>).forEach(k => {
      if (dist[k] < min) { min = dist[k]; zone = k; }
    });
    return zone;
  }

  private _dropHintEl: HTMLDivElement | null = null;

  _showDropHint(pane: DockPane, zone: DropZone): void {
    const r = pane.getBoundingClientRect();
    let { left, top, width, height } = r;
    if (zone === 'left')   width = r.width / 2;
    if (zone === 'right') { left = r.left + r.width / 2; width = r.width / 2; }
    if (zone === 'top')    height = r.height / 2;
    if (zone === 'bottom'){ top = r.top + r.height / 2; height = r.height / 2; }
    if (!this._dropHintEl) {
      this._dropHintEl = document.createElement('div');
      this._dropHintEl.style.cssText =
        "position: fixed; z-index: 100000; pointer-events: none;" +
        " background: rgba(54,140,232,0.25); border: 2px solid #3b82f6;" +
        " box-sizing: border-box; transition: all 60ms ease;";
      document.body.appendChild(this._dropHintEl);
    }
    const s = this._dropHintEl.style;
    s.left = `${left}px`; s.top = `${top}px`;
    s.width = `${width}px`; s.height = `${height}px`;
  }

  _hideDropHint(): void {
    this._dropHintEl?.remove();
    this._dropHintEl = null;
  }

  // Drop a dragged editor onto a target pane in the given zone:
  //   center  → add as a tab of the target
  //   edge    → split the target and place the editor in the new half
  dropEditor(source: LeafNode, iid: string, target: LeafNode, zone: DropZone, rect: DOMRect): void {
    if (zone === 'center') {
      if (source !== target) this.moveTab(source, target, iid);
      return;
    }
    const dir: 'h' | 'v' = (zone === 'left' || zone === 'right') ? 'h' : 'v';
    const newOnSecond = (zone === 'right' || zone === 'bottom');
    const size = dir === 'h' ? rect.width / 2 : rect.height / 2;
    this._splitWithEditor(target, dir, newOnSecond, size, source, iid);
  }

  // Split `target`, putting a fresh leaf (carrying the moved editor) on the
  // requested side.
  private _splitWithEditor(target: LeafNode, dir: 'h' | 'v', newOnSecond: boolean,
                           size: number, source: LeafNode, iid: string): void {
    const fresh: LeafNode = { type: 'leaf', id: newId('L'), tabs: [], active: 0 };
    const splitNode: SplitNode = {
      type: 'split', id: newId('S'), dir, size: Math.max(60, Math.round(size)),
      a: newOnSecond ? target : fresh,
      b: newOnSecond ? fresh : target,
    };
    const parent = this._parentOf(target);
    if (!parent) this._layout.root = splitNode;
    else { if (parent.a === target) parent.a = splitNode; else parent.b = splitNode; }

    // Move the editor into the fresh leaf.
    const idx = source.tabs.findIndex(t => t.iid === iid);
    if (idx >= 0) {
      const [tab] = source.tabs.splice(idx, 1);
      source.active = Math.max(0, Math.min(source.active, source.tabs.length - 1));
      fresh.tabs.push(tab);
      fresh.active = 0;
    }
    if (source.tabs.length === 0) this._collapseIfEmpty(source);
    this._touch();
  }

  // --- element lifecycle ---

  private _ensureEl(tab: TabState): HTMLElement | null {
    let el = this._els.get(tab.iid);
    if (el) return el;
    const def = this._def(tab.editorId);
    if (!def) return null;
    el = def.create();
    (el as HTMLElement).dataset.iid = tab.iid;
    (el as HTMLElement).style.flex = '1';
    this._els.set(tab.iid, el);
    this._host?.onMount?.(el, tab.editorId);
    return el;
  }

  private _destroyEl(iid: string): void {
    const el = this._els.get(iid);
    if (el) {
      el.remove();
      this._els.delete(iid);
    }
  }

  // --- tree traversal ---

  private _eachTab(fn: (tab: TabState, leaf: LeafNode) => void): void {
    const walk = (n: DockNode) => {
      if (n.type === 'leaf') n.tabs.forEach(t => fn(t, n));
      else { walk(n.a); walk(n.b); }
    };
    walk(this._layout.root);
    for (const f of this._layout.floats) f.node.tabs.forEach(t => fn(t, f.node));
  }

  // Find the parent split of a leaf (null if it is the tree root).
  private _parentOf(target: DockNode, n: DockNode = this._layout.root): SplitNode | null {
    if (n.type === 'leaf') return null;
    if (n.a === target || n.b === target) return n;
    return this._parentOf(target, n.a) ?? this._parentOf(target, n.b);
  }

  // --- mutations ---

  addEditor(leaf: LeafNode, editorId: string): void {
    if (this._def(editorId)?.singleton && this.editorsOf(editorId).length > 0) return;
    const tab: TabState = { iid: newId('E'), editorId };
    this._ensureEl(tab);
    leaf.tabs.push(tab);
    leaf.active = leaf.tabs.length - 1;
    this._touch();
  }

  removeTab(leaf: LeafNode, iid: string): void {
    const idx = leaf.tabs.findIndex(t => t.iid === iid);
    if (idx < 0) return;
    leaf.tabs.splice(idx, 1);
    leaf.active = Math.max(0, Math.min(leaf.active, leaf.tabs.length - 1));
    this._destroyEl(iid);
    // Collapse an emptied leaf that has a sibling; keep the sole root leaf.
    if (leaf.tabs.length === 0) this._collapseIfEmpty(leaf);
    this._touch();
  }

  // Move a tab from one leaf to another (drag between panes).
  moveTab(from: LeafNode, to: LeafNode, iid: string): void {
    if (from === to) return;
    const idx = from.tabs.findIndex(t => t.iid === iid);
    if (idx < 0) return;
    const [tab] = from.tabs.splice(idx, 1);
    from.active = Math.max(0, Math.min(from.active, from.tabs.length - 1));
    to.tabs.push(tab);
    to.active = to.tabs.length - 1;
    if (from.tabs.length === 0) this._collapseIfEmpty(from);
    this._touch();
  }

  // Replace a leaf with a split: existing leaf + a new empty leaf on `side`.
  split(leaf: LeafNode, dir: 'h' | 'v', newOnSecond: boolean): void {
    const fresh: LeafNode = { type: 'leaf', id: newId('L'), tabs: [], active: 0 };
    const splitNode: SplitNode = {
      type: 'split', id: newId('S'), dir, size: 240,
      a: newOnSecond ? leaf : fresh,
      b: newOnSecond ? fresh : leaf,
    };
    const parent = this._parentOf(leaf);
    if (!parent) {
      this._layout.root = splitNode;
    } else {
      if (parent.a === leaf) parent.a = splitNode; else parent.b = splitNode;
    }
    this._touch();
  }

  // Remove an empty leaf, replacing its parent split with the sibling.
  private _collapseIfEmpty(leaf: LeafNode): void {
    const parent = this._parentOf(leaf);
    if (!parent) return; // sole root leaf — leave it (it's interactable)
    const sibling = parent.a === leaf ? parent.b : parent.a;
    const grand = this._parentOf(parent);
    if (!grand) {
      this._layout.root = sibling;
    } else {
      if (grand.a === parent) grand.a = sibling; else grand.b = sibling;
    }
  }

  // Close a whole pane: destroy its editors and collapse it out of the tree
  // (the sole root leaf is kept but emptied).
  closePane(leaf: LeafNode): void {
    for (const tab of leaf.tabs.slice()) this._destroyEl(tab.iid);
    leaf.tabs = [];
    leaf.active = 0;
    this._collapseIfEmpty(leaf);
    this._touch();
  }

  // The floating panel that hosts this leaf, if any.
  private _floatOf(leaf: LeafNode): FloatPanel | undefined {
    return this._layout.floats.find(f => f.node === leaf);
  }

  // Detach a whole leaf into a floating panel.
  floatPane(leaf: LeafNode, x = 120, y = 120): void {
    const parent = this._parentOf(leaf);
    if (parent) {
      const sibling = parent.a === leaf ? parent.b : parent.a;
      const grand = this._parentOf(parent);
      if (!grand) this._layout.root = sibling;
      else { if (grand.a === parent) grand.a = sibling; else grand.b = sibling; }
    } else {
      // Floating the sole root leaf — leave a fresh empty root behind.
      this._layout.root = { type: 'leaf', id: newId('L'), tabs: [], active: 0 };
    }
    this._layout.floats.push({ id: newId('F'), node: leaf, x, y, w: 360, h: 280 });
    this._touch();
  }

  // Detach a single editor into a new floating panel.
  floatEditor(from: LeafNode, iid: string, x = 120, y = 120): void {
    const idx = from.tabs.findIndex(t => t.iid === iid);
    if (idx < 0) return;
    const [tab] = from.tabs.splice(idx, 1);
    from.active = Math.max(0, Math.min(from.active, from.tabs.length - 1));
    const leaf: LeafNode = { type: 'leaf', id: newId('L'), tabs: [tab], active: 0 };
    this._layout.floats.push({ id: newId('F'), node: leaf, x, y, w: 360, h: 280 });
    if (from.tabs.length === 0) this._collapseIfEmpty(from);
    this._touch();
  }

  closeFloat(panel: FloatPanel): void {
    for (const tab of panel.node.tabs) this._destroyEl(tab.iid);
    this._layout.floats = this._layout.floats.filter(f => f !== panel);
    this._touch();
  }

  // Dock a floating panel back into the main tree (split the root).
  dockFloat(panel: FloatPanel): void {
    this._layout.floats = this._layout.floats.filter(f => f !== panel);
    const root = this._layout.root;
    if (root.type === 'leaf' && root.tabs.length === 0) {
      this._layout.root = panel.node;
    } else {
      this._layout.root = {
        type: 'split', id: newId('S'), dir: 'h', size: 320,
        a: root, b: panel.node,
      };
    }
    this._touch();
  }

  // --- pane context menu (also used by empty panes) ---

  _showPaneMenu(leaf: LeafNode, x: number, y: number, floating: boolean): void {
    const used = new Set<string>();
    this._eachTab(t => used.add(t.editorId));
    const addItems: MenuItem[] = (this._host?.editors ?? []).map(def => ({
      label: def.title,
      disabled: !!def.singleton && used.has(def.id),
      action: () => this.addEditor(leaf, def.id),
    }));

    const items: MenuItem[] = [
      { label: 'Add editor', submenu: addItems },
      { separator: true },
    ];
    if (!floating) {
      items.push(
        { label: 'Split Left',  action: () => this.split(leaf, 'h', true) },
        { label: 'Split Right', action: () => this.split(leaf, 'h', false) },
        { label: 'Split Up',    action: () => this.split(leaf, 'v', true) },
        { label: 'Split Down',  action: () => this.split(leaf, 'v', false) },
        { separator: true },
        { label: 'Float pane', disabled: leaf.tabs.length === 0, action: () => this.floatPane(leaf, x, y) },
      );
    }
    items.push({ separator: true });
    if (floating) {
      const panel = this._floatOf(leaf);
      items.push({ label: 'Close pane', action: () => panel && this.closeFloat(panel) });
    } else {
      items.push({ label: 'Close pane', action: () => this.closePane(leaf) });
    }
    showMenu(x, y, items);
  }

  // --- persistence ---

  _touch(): void {
    // Drop floating panels whose editor was dragged/closed away.
    this._layout.floats = this._layout.floats.filter(f => f.node.tabs.length > 0);
    this._rev++;
    this.requestUpdate();
    this._save();
    this.dispatchEvent(new CustomEvent('dock-changed', { bubbles: true, composed: true }));
  }

  private _save(): void {
    const key = this._host?.storageKey;
    if (!key) return;
    try {
      localStorage.setItem(key, JSON.stringify(this._layout));
    } catch { /* ignore quota errors */ }
  }

  private _load(): void {
    const key = this._host?.storageKey;
    let layout: Layout | null = null;
    if (key) {
      try {
        const saved = localStorage.getItem(key);
        if (saved) layout = this._sanitize(JSON.parse(saved));
      } catch { layout = null; }
    }
    if (!layout) layout = this._host!.defaultLayout();
    this._layout = layout;
    // Re-seed the id counter past any persisted ids so new ids stay unique.
    this._bumpCounter(layout);
    // Instantiate + wire every persisted editor up front.
    this._eachTab(tab => this._ensureEl(tab));
    this.requestUpdate();
  }

  // Drop tabs referencing unknown editor ids and enforce singletons.
  private _sanitize(layout: Layout): Layout {
    const seen = new Set<string>();
    const fixLeaf = (leaf: LeafNode): LeafNode => {
      leaf.tabs = leaf.tabs.filter(t => {
        const def = this._def(t.editorId);
        if (!def) return false;
        if (def.singleton) { if (seen.has(def.id)) return false; seen.add(def.id); }
        if (!t.iid) t.iid = newId('E');
        return true;
      });
      leaf.active = Math.max(0, Math.min(leaf.active | 0, leaf.tabs.length - 1));
      return leaf;
    };
    const fix = (n: DockNode): DockNode => {
      if (n.type === 'leaf') return fixLeaf(n);
      n.a = fix(n.a); n.b = fix(n.b);
      // Collapse a split whose child became an empty leaf.
      const emptyA = n.a.type === 'leaf' && n.a.tabs.length === 0;
      const emptyB = n.b.type === 'leaf' && n.b.tabs.length === 0;
      if (emptyA && !emptyB) return n.b;
      if (emptyB && !emptyA) return n.a;
      return n;
    };
    layout.root = fix(layout.root);
    layout.floats = (layout.floats ?? []).map(f => { fixLeaf(f.node); return f; })
      .filter(f => f.node.tabs.length > 0);
    return layout;
  }

  private _bumpCounter(layout: Layout): void {
    const nums: number[] = [];
    const grab = (s: string | undefined) => { if (s) { const m = /(\d+)$/.exec(s); if (m) nums.push(+m[1]); } };
    const walk = (n: DockNode) => {
      grab(n.id);
      if (n.type === 'leaf') n.tabs.forEach(t => grab(t.iid));
      else { walk(n.a); walk(n.b); }
    };
    walk(layout.root);
    for (const f of layout.floats) { grab(f.id); walk(f.node); }
    _idCounter = Math.max(_idCounter, ...nums.map(n => n + 1), 1);
  }

  // --- rendering ---

  private _renderNode(node: DockNode): unknown {
    if (node.type === 'leaf') {
      return keyed(node.id, html`<dock-pane
        .root="${this}" .node="${node}" .rev="${this._rev}"
      ></dock-pane>`);
    }
    const dir = node.dir === 'h' ? 'horizontal' : 'vertical';
    return keyed(node.id, html`<split-pane
      direction="${dir}"
      initial-size="${node.size}"
      min-size="60"
      @split-resize="${(e: CustomEvent) => {
        // split-resize bubbles+composed; ignore events from nested split-panes
        // so an inner divider drag doesn't overwrite this (ancestor) node's size.
        if (e.target !== e.currentTarget) return;
        node.size = e.detail.size;
        this._save();
      }}"
    >
      <div slot="first" class="cell">${this._renderNode(node.a)}</div>
      <div slot="second" class="cell">${this._renderNode(node.b)}</div>
    </split-pane>`);
  }

  private _renderFloat(panel: FloatPanel): unknown {
    return keyed(panel.id, html`<div
      class="float"
      style="left:${panel.x}px; top:${panel.y}px; width:${panel.w}px; height:${panel.h}px;"
    >
      <div class="float-title"
        @mousedown="${(e: MouseEvent) => this._startFloatDrag(e, panel)}">
        <span class="float-name">${this._floatName(panel)}</span>
        <span class="float-btn" title="Dock"
          @mousedown="${(e: MouseEvent) => e.stopPropagation()}"
          @click="${() => this.dockFloat(panel)}">▤</span>
        <span class="float-btn" title="Close"
          @mousedown="${(e: MouseEvent) => e.stopPropagation()}"
          @click="${() => this.closeFloat(panel)}">×</span>
      </div>
      <div class="float-body">
        <dock-pane .root="${this}" .node="${panel.node}" .rev="${this._rev}" .floating="${true}"></dock-pane>
      </div>
      <div class="float-resize"
        @mousedown="${(e: MouseEvent) => this._startFloatResize(e, panel)}"></div>
    </div>`);
  }

  private _floatName(panel: FloatPanel): string {
    return panel.node.tabs.map(t => this._def(t.editorId)?.title ?? t.editorId).join(', ') || 'float';
  }

  private _startFloatDrag(e: MouseEvent, panel: FloatPanel): void {
    e.preventDefault();
    const ox = e.clientX - panel.x;
    const oy = e.clientY - panel.y;
    const move = (ev: MouseEvent) => {
      panel.x = Math.max(0, ev.clientX - ox);
      panel.y = Math.max(0, ev.clientY - oy);
      this.requestUpdate();
    };
    const up = () => {
      document.removeEventListener('mousemove', move, true);
      document.removeEventListener('mouseup', up, true);
      this._save();
    };
    document.addEventListener('mousemove', move, true);
    document.addEventListener('mouseup', up, true);
  }

  private _startFloatResize(e: MouseEvent, panel: FloatPanel): void {
    e.preventDefault();
    e.stopPropagation();
    const sx = e.clientX, sy = e.clientY, sw = panel.w, sh = panel.h;
    const move = (ev: MouseEvent) => {
      panel.w = Math.max(160, sw + (ev.clientX - sx));
      panel.h = Math.max(100, sh + (ev.clientY - sy));
      this.requestUpdate();
    };
    const up = () => {
      document.removeEventListener('mousemove', move, true);
      document.removeEventListener('mouseup', up, true);
      this._save();
    };
    document.addEventListener('mousemove', move, true);
    document.addEventListener('mouseup', up, true);
  }

  render() {
    return html`
      <div id="main">${this._renderNode(this._layout.root)}</div>
      <div id="floats">${this._layout.floats.map(f => this._renderFloat(f))}</div>
    `;
  }

  static styles = css`
    :host {
      display: block;
      position: relative;
      flex: 1;
      min-height: 0;
      min-width: 0;
      overflow: hidden;
    }
    #main {
      position: absolute;
      inset: 0;
      display: flex;
    }
    .cell {
      flex: 1;
      display: flex;
      min-height: 0;
      min-width: 0;
      overflow: hidden;
    }
    #floats {
      position: absolute;
      inset: 0;
      pointer-events: none;
    }
    .float {
      position: absolute;
      pointer-events: auto;
      display: flex;
      flex-direction: column;
      background: #111;
      border: 1px solid #555;
      box-shadow: 3px 3px 12px rgba(0,0,0,0.6);
      overflow: hidden;
      min-width: 0;
      min-height: 0;
    }
    .float-title {
      flex: 0 0 auto;
      display: flex;
      align-items: center;
      gap: 4px;
      padding: 2px 4px 2px 8px;
      background: #2b2b2b;
      border-bottom: 1px solid #444;
      cursor: move;
      user-select: none;
    }
    .float-name {
      flex: 1;
      font: 10px 'Consolas for Powerline', Consolas, monospace;
      color: #ccc;
      white-space: nowrap;
      overflow: hidden;
      text-overflow: ellipsis;
    }
    .float-btn {
      cursor: pointer;
      color: #aaa;
      padding: 0 5px;
      font-size: 13px;
      line-height: 1;
    }
    .float-btn:hover { color: #fff; }
    .float-body {
      flex: 1;
      display: flex;
      min-height: 0;
      min-width: 0;
      overflow: hidden;
    }
    .float-resize {
      position: absolute;
      right: 0;
      bottom: 0;
      width: 14px;
      height: 14px;
      cursor: nwse-resize;
      background: linear-gradient(135deg, transparent 50%, #666 50%, #666 60%, transparent 60%, transparent 75%, #666 75%, #666 85%, transparent 85%);
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'dock-root': DockRoot;
    'dock-pane': DockPane;
  }
}
