import {LitElement, html, css} from 'lit';
import {customElement} from 'lit/decorators.js';

@customElement('gpc-sections')
export class GpcSections extends LitElement {

  // --- Properties set by host via JS ---
  sym: any = null;
  selectedSection: string | null = null;

  // --- Internal refs ---
  private _contentEl: HTMLDivElement | null = null;

  // --- Lit lifecycle ---

  firstUpdated(): void {
    this._contentEl = this.shadowRoot!.getElementById('content') as HTMLDivElement;
  }

  // --- Public methods ---

  refresh(): void {
    const container = this._contentEl;
    if (!container) return;

    container.innerHTML = '';

    if (!this.sym?.sectionsByAddr || this.sym.sectionsByAddr.length === 0) {
      const noSections = document.createElement('div');
      noSections.style.cssText = 'color: #666; font-style: italic; padding: 4px;';
      noSections.textContent = 'No sections';
      container.appendChild(noSections);
      return;
    }

    for (const sect of this.sym.sectionsByAddr) {
      const sectDiv = document.createElement('div');
      sectDiv.style.cssText = 'padding: 2px 4px; margin-bottom: 1px; cursor: pointer; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;';
      sectDiv.style.backgroundColor = this.sym.sectionColors?.[sect.name] || '#333';
      sectDiv.style.color = '#ddd';
      sectDiv.style.fontSize = '10px';
      sectDiv.style.lineHeight = '14px';

      // Highlight selected section with bright border and inverted colors
      if (this.selectedSection === sect.name) {
        sectDiv.style.border = '2px solid #ff0';
        sectDiv.style.backgroundColor = '#ff0';
        sectDiv.style.color = '#000';
        sectDiv.style.fontWeight = 'bold';
      }

      const addrStart = sect.address.toString(16).padStart(5, '0');
      const addrEnd = (sect.address + sect.size - 1).toString(16).padStart(5, '0');
      sectDiv.textContent = `${addrStart} ${sect.name.substring(0, 10)}`;
      sectDiv.title = `${sect.name}: 0x${addrStart}-0x${addrEnd} (${sect.size} words)`;

      // Click to toggle selection
      const sectionName = sect.name;
      sectDiv.onclick = (_e: MouseEvent) => {
        if (this.selectedSection === sectionName) {
          this.selectedSection = null;
        } else {
          this.selectedSection = sectionName;
        }
        this.dispatchEvent(new CustomEvent('section-selected', {
          detail: { name: this.selectedSection },
          bubbles: true,
          composed: true,
        }));
        this.refresh();
      };

      container.appendChild(sectDiv);
    }
  }

  // --- Template ---

  render() {
    return html`
      <div id="header">SECTIONS</div>
      <div id="content"></div>
    `;
  }

  // --- Styles ---

  static styles = css`
    :host {
      display: flex;
      flex-direction: column;
      overflow: hidden;
      padding-left: 4px;
      font-family: 'Consolas for Powerline', Consolas, monospace;
      min-height: 0;
      min-width: 0;
      flex: 1;
    }

    #header {
      color: #888;
      font-size: 9px;
      margin-bottom: 4px;
      padding-bottom: 2px;
      border-bottom: 1px solid #333;
      flex: 0 0 auto;
    }

    #content {
      flex: 1;
      overflow: auto;
    }
  `;
}

declare global {
  interface HTMLElementTagNameMap {
    'gpc-sections': GpcSections;
  }
}
