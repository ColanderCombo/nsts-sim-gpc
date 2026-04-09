import {LitElement, html, css} from 'lit';
import {customElement, property} from 'lit/decorators.js';

/**
 * <split-pane> — A two-panel split container with a draggable divider.
 *
 * Usage:
 *   <split-pane direction="horizontal" initial-size="300" min-size="60">
 *     <div slot="first">...</div>
 *     <div slot="second">...</div>
 *   </split-pane>
 *
 * Properties:
 *   direction    "horizontal" (left|right) or "vertical" (top|bottom)
 *   initial-size  Starting size in px of the SECOND panel (for horizontal)
 *                 or BOTTOM panel (for vertical). The first panel gets flex:1.
 *   min-size      Minimum size in px for the sized panel (default 60)
 *   save-key      If set, persists size to localStorage under this key
 *
 * Events:
 *   split-resize  Fired during/after drag with detail: { size: number }
 */
@customElement('split-pane')
export class SplitPane extends LitElement {

  @property({ attribute: 'direction' }) declare direction: string;
  @property({ type: Number, attribute: 'initial-size' }) declare initialSize: number;
  @property({ type: Number, attribute: 'min-size' }) declare minSize: number;
  @property({ attribute: 'save-key' }) declare saveKey: string;

  private _size: number = 0;
  private _dragging: boolean = false;
  private _dragStart: number = 0;
  private _dragStartSize: number = 0;

  constructor() {
    super();
    this.direction = 'horizontal';
    this.initialSize = 200;
    this.minSize = 60;
    this.saveKey = '';
  }

  connectedCallback() {
    super.connectedCallback();
    // Restore from localStorage or use initial
    if (this.saveKey) {
      const saved = localStorage.getItem(`split-pane:${this.saveKey}`);
      if (saved) {
        this._size = Math.max(this.minSize, parseInt(saved, 10) || this.initialSize);
      } else {
        this._size = this.initialSize;
      }
    } else {
      this._size = this.initialSize;
    }
  }

  get size(): number {
    return this._size;
  }

  set size(v: number) {
    this._size = Math.max(this.minSize, v);
    this._applySize();
  }

  private _isVertical(): boolean {
    return this.direction === 'vertical';
  }

  private _applySize(): void {
    const secondDiv = this.shadowRoot?.getElementById('second') as HTMLElement | null;
    if (!secondDiv) return;
    if (this._isVertical()) {
      secondDiv.style.height = `${this._size}px`;
      secondDiv.style.width = '';
    } else {
      secondDiv.style.width = `${this._size}px`;
      secondDiv.style.height = '';
    }
  }

  firstUpdated(): void {
    this._applySize();
  }

  private _onSplitterDown(e: MouseEvent): void {
    e.preventDefault();
    this._dragging = true;
    this._dragStart = this._isVertical() ? e.clientY : e.clientX;
    this._dragStartSize = this._size;
    document.body.style.cursor = this._isVertical() ? 'ns-resize' : 'col-resize';
    document.body.style.userSelect = 'none';
    document.addEventListener('mousemove', this._onMouseMove);
    document.addEventListener('mouseup', this._onMouseUp);
  }

  private _onMouseMove = (e: MouseEvent): void => {
    if (!this._dragging) return;
    const pos = this._isVertical() ? e.clientY : e.clientX;
    // Dragging splitter down/right = making second pane smaller (negative delta)
    const delta = (this._dragStart - pos);
    const newSize = Math.max(this.minSize, this._dragStartSize + delta);
    this._size = newSize;
    this._applySize();
    this.dispatchEvent(new CustomEvent('split-resize', {
      detail: { size: this._size },
      bubbles: true,
      composed: true,
    }));
  };

  private _onMouseUp = (_e: MouseEvent): void => {
    if (!this._dragging) return;
    this._dragging = false;
    document.body.style.cursor = '';
    document.body.style.userSelect = '';
    document.removeEventListener('mousemove', this._onMouseMove);
    document.removeEventListener('mouseup', this._onMouseUp);
    if (this.saveKey) {
      localStorage.setItem(`split-pane:${this.saveKey}`, String(this._size));
    }
    this.dispatchEvent(new CustomEvent('split-resize', {
      detail: { size: this._size },
      bubbles: true,
      composed: true,
    }));
  };

  render() {
    const isV = this._isVertical();
    return html`
      <div id="container" class="${isV ? 'vertical' : 'horizontal'}">
        <div id="first"><slot name="first"></slot></div>
        <div id="splitter"
          @mousedown="${this._onSplitterDown}"
          @mouseenter="${(e: MouseEvent) => (e.target as HTMLElement).style.backgroundColor = '#555'}"
          @mouseleave="${(e: MouseEvent) => { if (!this._dragging) (e.target as HTMLElement).style.backgroundColor = '#333'; }}">
        </div>
        <div id="second" style="${isV ? `height:${this._size}px` : `width:${this._size}px`}">
          <slot name="second"></slot>
        </div>
      </div>
    `;
  }

  static styles = css`
    :host {
      display: flex;
      flex: 1;
      overflow: hidden;
      min-height: 0;
      min-width: 0;
    }

    #container {
      display: flex;
      flex: 1;
      overflow: hidden;
      min-height: 0;
      min-width: 0;
    }

    #container.horizontal {
      flex-direction: row;
    }

    #container.vertical {
      flex-direction: column;
    }

    #first {
      flex: 1;
      overflow: hidden;
      min-height: 0;
      min-width: 0;
      display: flex;
    }

    #first > ::slotted(*) {
      flex: 1;
      min-height: 0;
      min-width: 0;
    }

    #second {
      overflow: hidden;
      flex: 0 0 auto;
      display: flex;
      min-height: 0;
      min-width: 0;
    }

    #second > ::slotted(*) {
      flex: 1;
      min-height: 0;
      min-width: 0;
    }

    .horizontal > #splitter {
      width: 3px;
      cursor: col-resize;
      background-color: #333;
      flex: 0 0 auto;
    }

    .vertical > #splitter {
      height: 3px;
      cursor: ns-resize;
      background-color: #333;
      flex: 0 0 auto;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'split-pane': SplitPane;
  }
}
