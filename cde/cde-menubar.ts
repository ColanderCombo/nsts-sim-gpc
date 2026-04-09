import {LitElement, html, css} from 'lit';
import {customElement, property, state} from 'lit/decorators.js';

/**
 * <cde-menubar> — CDE-style menu bar.
 *
 * Declarative usage:
 *
 *   <cde-menubar>
 *     <cde-menu label="File">
 *       <cde-menu-item label="Quit" shortcut="Cmd+Q" action="quit"></cde-menu-item>
 *     </cde-menu>
 *   </cde-menubar>
 *
 */
@customElement('cde-menubar')
export class CdeMenubar extends LitElement {

  @state() declare private _openMenu: string | null;

  constructor() {
    super();
    this._openMenu = null;
  }

  private get _ipc() {
    return (window as any).ipcRenderer;
  }

  connectedCallback() {
    super.connectedCallback();
    document.addEventListener('mousedown', this._closeOnOutsideClick);
    this.addEventListener('cde-menu-open', this._onMenuOpen as EventListener);
    this.addEventListener('cde-menu-action', this._onMenuAction as EventListener);
  }

  disconnectedCallback() {
    super.disconnectedCallback();
    document.removeEventListener('mousedown', this._closeOnOutsideClick);
    this.removeEventListener('cde-menu-open', this._onMenuOpen as EventListener);
    this.removeEventListener('cde-menu-action', this._onMenuAction as EventListener);
  }

  private _menus(): CdeMenu[] {
    const slot = this.shadowRoot?.querySelector('slot') as HTMLSlotElement | null;
    if (!slot) return [];
    return slot.assignedElements({ flatten: true })
      .filter((el): el is CdeMenu => el.tagName?.toLowerCase() === 'cde-menu');
  }

  private _onMenuOpen = (e: CustomEvent) => {
    const label = (e.detail?.label ?? null) as string | null;
    this._openMenu = label;
    for (const m of this._menus()) {
      if (m.label !== label) m.open = false;
    }
  };

  private _onMenuAction = (e: CustomEvent) => {
    this._openMenu = null;
    for (const m of this._menus()) m.open = false;

    const action = e.detail?.action as string | undefined;
    switch (action) {
      case 'quit':
      case 'close':
        this._ipc?.send('window-close');
        break;
      case 'devtools':
        this._ipc?.send('toggle-devtools');
        break;
    }
  };

  private _closeOnOutsideClick = (e: Event) => {
    if (this._openMenu == null) return;
    const path = e.composedPath();
    if (path.includes(this)) return;
    this._openMenu = null;
    for (const m of this._menus()) m.open = false;
  };

  render() {
    return html`<div id="menubar"><slot></slot></div>`;
  }

  static styles = css`
      :host {
        display: block;
        flex: 0 0 auto;

        --cde-menubar-bg:        rgb(96,129,251);
        --cde-menubar-light:     rgb(90,156,247);
        --cde-menubar-dark:      rgb(30,65,208);
        --cde-menubar-hover-bg:  rgb(30,65,208);
        --cde-menubar-hover-fg:  white;
        --cde-menubar-fg:        black;

        background-color: var(--cde-menubar-bg);
        border-top:    1px solid var(--cde-menubar-light);
        border-left:   1px solid var(--cde-menubar-light);
        border-right:  1px solid var(--cde-menubar-dark);
        border-bottom: 1px solid var(--cde-menubar-dark);
        font-family: "Consolas for Powerline", Consolas, "Helvetica", sans-serif;
        font-size: 11px;
        color: var(--cde-menubar-fg);
        -webkit-user-select: none;
        user-select: none;
      }

      #menubar {
        display: flex;
        align-items: stretch;
        padding: 0 2px;
        height: 18px;
      }
  `;
}


@customElement('cde-menu')
export class CdeMenu extends LitElement {

  @property() declare label: string;
  @property({ type: Boolean, reflect: true }) declare open: boolean;

  constructor() {
    super();
    this.label = '';
    this.open = false;
  }

  private _onLabelClick = (e: Event) => {
    e.stopPropagation();
    this.open = !this.open;
    this.dispatchEvent(new CustomEvent('cde-menu-open', {
      bubbles: true,
      composed: true,
      detail: { label: this.open ? this.label : null },
    }));
  };

  private _swallow = (e: Event) => {
    e.stopPropagation();
  };

  render() {
    return html`
      <div id="menu-label" class="${this.open ? 'open' : ''}" @click="${this._onLabelClick}">${this.label}</div>
      ${this.open ? html`
        <div id="menu-pane" @click="${this._swallow}">
          <slot></slot>
        </div>
      ` : ''}
    `;
  }

  static styles = css`
      :host {
        position: relative;
        display: inline-flex;
        align-items: stretch;
      }

      #menu-label {
        padding: 0 8px;
        line-height: 18px;
        cursor: pointer;
        color: black;
        white-space: nowrap;
      }

      #menu-label:hover, #menu-label.open {
        background-color: rgb(30,65,208);
        color: white;
      }

      #menu-pane {
        position: absolute;
        left: 0;
        top: 100%;
        z-index: 10000;
        min-width: 160px;
        background-color: rgb(96,129,251);
        border-left:   2px solid rgb(90,156,247);
        border-top:    2px solid rgb(90,156,247);
        border-right:  2px solid rgb(30,65,208);
        border-bottom: 2px solid rgb(30,65,208);
        padding: 2px 0;
        font-family: "Consolas for Powerline", Consolas, "Helvetica", sans-serif;
        font-size: 11px;
      }
  `;
}


@customElement('cde-menu-item')
export class CdeMenuItem extends LitElement {

  // See note on CdeMenubar._openMenu for why these use `declare`.
  @property() declare label: string;
  @property() declare shortcut: string;
  @property() declare action: string;
  @property({ type: Boolean }) declare disabled: boolean;

  constructor() {
    super();
    this.label = '';
    this.shortcut = '';
    this.action = '';
    this.disabled = false;
  }

  private _onClick = (e: Event) => {
    if (this.disabled) return;
    e.stopPropagation();
    this.dispatchEvent(new CustomEvent('cde-menu-action', {
      bubbles: true,
      composed: true,
      detail: { action: this.action, label: this.label },
    }));
  };

  render() {
    return html`
      <div class="item ${this.disabled ? 'disabled' : ''}" @click="${this._onClick}">
        <span class="item-label">${this.label}</span>
        ${this.shortcut ? html`<span class="item-shortcut">${this.shortcut}</span>` : ''}
      </div>
    `;
  }

  static styles = css`
      :host { display: block; }

      .item {
        display: flex;
        justify-content: space-between;
        padding: 2px 12px;
        color: black;
        cursor: pointer;
        white-space: nowrap;
        font-family: "Consolas for Powerline", Consolas, "Helvetica", sans-serif;
        font-size: 11px;
      }

      .item:hover:not(.disabled) {
        background-color: rgb(30,65,208);
        color: white;
      }

      .item.disabled {
        color: rgb(30,65,208);
        cursor: default;
      }

      .item-shortcut {
        margin-left: 24px;
      }
  `;
}


declare global {
  interface HTMLElementTagNameMap {
    'cde-menubar': CdeMenubar;
    'cde-menu': CdeMenu;
    'cde-menu-item': CdeMenuItem;
  }
}
