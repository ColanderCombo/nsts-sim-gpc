
import {LitElement, html, css} from 'lit';
import {property, customElement} from 'lit/decorators.js';

@customElement('cde-window')
export class CdeWindow extends LitElement {

	@property() title: string = "CDE Window";
	@property() resizable: boolean = true;
	@property() hasFrame: boolean = true;
	@property() theme: string = "nblue";

	static override properties = {
		...LitElement.properties,
		_menuOpen: { state: true },
	};

	_menuOpen: boolean = false;

  constructor() {
    super()
    this._menuOpen = false;
  }

  private get _ipc() {
    return (window as any).ipcRenderer;
  }

	_minimize(e: Event): void {
		this._ipc?.send('window-minimize');
	}

	_maximize(e: Event): void {
		this._ipc?.send('window-maximize');
	}

	_menu(e: Event): void {
		e.stopPropagation();
		this._menuOpen = !this._menuOpen;
		console.log("CDE _menu clicked, _menuOpen =", this._menuOpen);
		this.requestUpdate();
	}

	_menuAction(action: string): void {
		this._menuOpen = false;
		switch (action) {
			case 'restore':
				this._ipc?.send('window-maximize');
				break;
			case 'minimize':
				this._ipc?.send('window-minimize');
				break;
			case 'maximize':
				this._ipc?.send('window-maximize');
				break;
			case 'close':
				this._ipc?.send('window-close');
				break;
			case 'devtools':
				this._ipc?.send('toggle-devtools');
				break;
		}
	}

	connectedCallback() {
		super.connectedCallback();
		this._closeMenuOnClick = this._closeMenuOnClick.bind(this);
		document.addEventListener('mousedown', this._closeMenuOnClick);
	}

	disconnectedCallback() {
		super.disconnectedCallback();
		document.removeEventListener('mousedown', this._closeMenuOnClick);
	}

	private _closeMenuOnClick(e: Event) {
		if (!this._menuOpen) return;
		// Check if the mousedown is inside our menu or menu button
		const path = e.composedPath();
		const menu = this.shadowRoot?.getElementById('cde-menu');
		const menuBut = this.shadowRoot?.getElementById('menubut');
		if (menu && path.includes(menu)) return;
		if (menuBut && path.includes(menuBut)) return;
		console.log("CDE closing menu from outside mousedown");
		this._menuOpen = false;
	}

	render() {
		console.log("CDE render(), _menuOpen =", this._menuOpen);
		return html`
		<div id="cde-deco" class="cde-theme-nblue cde-compute">
		${this.theme}
		<div id="menubut" class="cde-active-button" @click="${this._menu}"><div id="menubut-icon"></div></div>
		${this._menuOpen ? html`
			<div id="cde-menu" @click="${(e: Event) => e.stopPropagation()}">
				<div class="cde-menu-item" @click="${() => this._menuAction('restore')}">Restore</div>
				<div class="cde-menu-item disabled">Move</div>
				<div class="cde-menu-item disabled">Size</div>
				<div class="cde-menu-item" @click="${() => this._menuAction('minimize')}">Minimize</div>
				<div class="cde-menu-item" @click="${() => this._menuAction('maximize')}">Maximize</div>
				<div class="cde-menu-item disabled">Lower</div>
				<div class="cde-menu-item disabled">Occupy Workspace</div>
				<div class="cde-menu-item disabled">Occupy All Workspaces</div>
				<div class="cde-menu-separator"></div>
				<div class="cde-menu-item" @click="${() => this._menuAction('devtools')}">DevTools</div>
				<div class="cde-menu-separator"></div>
				<div class="cde-menu-item" @click="${() => this._menuAction('close')}">Close</div>
			</div>
		` : ''}
		<div id="title"><span id="title-text">${this.title}</span></div>
	 	<div id="minbut" class="cde-active-button" @click="${this._minimize}"><div id="minbut-icon"></div></div>
	 	<div id="maxbut" class="cde-active-button" @click="${this._maximize}"><div id="maxbut-icon"></div></div>
		  	${(this.resizable==true)?
		  		html`
		  		<div id="c-ull"></div><div id="c-ulc"></div><div id="c-ulr"></div>
		  		<div id="border-inner-top"></div>
		  		<div id="c-url"></div><div id="c-urc"></div><div id="c-urr"></div>
		  		<div id="border-inner-right"></div>
		  		<div id="c-brl"></div><div id="c-brc"></div><div id="c-brr"></div>
		  		<div id="border-inner-bottom"></div>
		  		<div id="c-bll"></div><div id="c-blc"></div><div id="c-blr"></div>
		  		<div id="border-inner-left"></div>
		  		  `:
		  		html`
		  		<div id="border-top"></div>
		  		<div id="c-ulc"></div>
		  		<div id="border-right"></div>
		  		<div id="c-urc"></div>
		  		<div id="border-bottom"></div>
		  		<div id="c-brc"></div>
		  		<div id="border-left"></div>
		  		<div id="c-blc"></div>

		  		`
		  	}
		 </div>
		 <div id="cde-content" class="cde-theme-nblue cde-compute"><slot></slot></div>
		`;
	}

	static get styles() {
		return [
			css`
			.cde-theme-gray {
				--titlebar-color:white;
				--box-color: rgb(140,139,140);
				--box-border-light: rgb(204,203,204);
				--box-border-dark: rgb(60,60,60);
				--menu-background-color: rgb(58,131,154);
				--menu-border-light:rgb(165,200,209);
				--menu-border-dark:rgb(20,56,65);
				--content-background-color: rgb(191,168,158);
				--content-light-color: rgb(227,218,213);
				--content-dark-color: rgb(89,79,73);
				--lowered-background-color: rgb(157,137,129);
				--lowered-light-color: rgb(227,218,213);
				--lowered-dark-color: rgb(89,79,73);

				--win-border-width: 8px;
				--win-icon-size: 20px;
				--win-box-border: 1px;
			  }

			  .cde-theme-orange {
				--titlebar-color:white;
				--box-color: rgb(223,156,100);
				--box-border-light: rgb(245,212,186);
				--box-border-dark: rgb(108,71,44);
				--menu-background-color: rgb(58,131,154);
				--menu-border-light:rgb(165,200,209);
				--menu-border-dark:rgb(20,56,65);
				--content-background-color: rgb(191,168,158);
				--content-light-color: rgb(227,218,213);
				--content-dark-color: rgb(89,79,73);
				--lowered-background-color: rgb(157,137,129);
				--lowered-light-color: rgb(227,218,213);
				--lowered-dark-color: rgb(89,79,73);

				--win-border-width: 8px;
				--win-icon-size: 20px;
				--win-box-border: 1px;
			  }

			  .cde-theme-nblue  {
				--titlebar-color:black;
				--box-color: rgb(96,129,251);
				--box-border-light: rgb(90,156,247);
				--box-border-dark: rgb(30,65,208);
				--menu-background-color: rgb(58,131,154);
				--menu-border-light:rgb(165,200,209);
				--menu-border-dark:rgb(20,56,65);
				--content-background-color: rgb(191,168,158);
				--content-light-color: rgb(227,218,213);
				--content-dark-color: rgb(89,79,73);
				--lowered-background-color: rgb(157,137,129);
				--lowered-light-color: rgb(227,218,213);
				--lowered-dark-color: rgb(89,79,73);

				--win-border-width: 5px;
				--win-icon-size: 20px;
				--win-box-border: 1px;
			  }

			  .cde-compute  {
				--win-icon-innerWidth: calc(var(--win-icon-size) - 2 * var(--win-box-border));
				--win-border-innerWidth: calc(var(--win-border-width) - 2 * var(--win-box-border));
				--win-border-seg-width: calc(100% - (2 * var(--win-icon-size)) - (2 * var(--win-border-width)) - (2 * var(--win-box-border)));
				--win-border-seg-offset-beg: calc(0px + var(--win-border-width) + var(--win-icon-size));
				--win-cc-width: calc(var(--win-border-innerWidth) + var(--win-box-border));
			  }

			  #cde-deco div {
				background-color: var(--box-color);
				border-left: 1px solid var(--box-border-light);
				border-top: 1px solid var(--box-border-light);
				border-right: 1px solid var(--box-border-dark);
				border-bottom: 1px solid var(--box-border-dark);
			  }

			  .lowered {
				background-color: var(--box-color);
				border-left: 1px solid var(--box-border-dark);
				border-top: 1px solid var(--box-border-dark);
				border-right: 1px solid var(--box-border-light);
				border-bottom: 1px solid var(--box-border-light);
			  }

			  cde-window {
				  position:relative;
				  left:0px;
				  top:0px;
				  width:100%;
				  height:100%;
			  }


			  .cde-setting-noresize {
				/*-webkit-app-region: drag;*/
			  }

			  #cde-deco {
				  position:absolute;
				  left:0px;
				  top:0px;
				  width:100%;
				  height:100%;
				  -webkit-app-region:no-drag;
			  }

			  #menubut {
				position: absolute;
				left: var(--win-border-width);
				top: var(--win-border-width);
				width: var(--win-icon-innerWidth);
				height: var(--win-icon-innerWidth);
				cursor: pointer;
			  }

			  #menubut:active {
				background-color: var(--box-color);
				border-left: 1px solid var(--box-border-dark);
				border-top: 1px solid var(--box-border-dark);
				border-right: 1px solid var(--box-border-light);
				border-bottom: 1px solid var(--box-border-light);
			  }

			  #menubut-icon {
				position: relative;
				top: 38.889%;
				height:11.111%;
				left: 16.667%;
				width: 55%;
			  }

			  /* ---- CDE Window Menu ---- */
			  #cde-menu {
				position: absolute;
				left: var(--win-border-width);
				top: calc(var(--win-border-width) + var(--win-icon-size) + 1px);
				z-index: 10000;
				min-width: 180px;
				background-color: var(--box-color);
				border-left: 2px solid var(--box-border-light);
				border-top: 2px solid var(--box-border-light);
				border-right: 2px solid var(--box-border-dark);
				border-bottom: 2px solid var(--box-border-dark);
				padding: 2px 0;
				font-family: "Consolas for Powerline", Consolas, "Helvetica", sans-serif;
				font-size: 11px;
			  }

			  .cde-menu-item {
				padding: 2px 12px;
				color: black;
				cursor: pointer;
				white-space: nowrap;
				background-color: var(--box-color) !important;
				border: none !important;
			  }

			  .cde-menu-item:hover:not(.disabled) {
				background-color: var(--box-border-dark) !important;
				color: white;
			  }

			  .cde-menu-item.disabled {
				color: var(--box-border-dark);
				cursor: default;
			  }

			  .cde-menu-separator {
				height: 1px;
				margin: 2px 4px;
				border: none !important;
				border-top: 1px solid var(--box-border-dark) !important;
				border-bottom: 1px solid var(--box-border-light) !important;
				background-color: transparent !important;
			  }

			  #title {
				-webkit-app-region:drag;
				position: absolute;
				left: var(--win-border-seg-offset-beg);
				top: var(--win-border-width);
				width: calc(var(--win-border-seg-width) - var(--win-icon-size));
				height: var(--win-icon-innerWidth);
				color: var(--titlebar-color);
				-webkit-user-select: none;
				-webkit-app-region: drag;
				font-family: "Consolas for Powerline", Consolas, monospace;
				text-align: center;
			  }

			  #title-text {line-height: var(--win-icon-size); white-space:nowrap;}

			  #minbut {
				position: absolute;
				left: calc(var(--win-border-seg-offset-beg) + var(--win-border-seg-width) - var(--win-icon-size) + 2 * var(--win-box-border));
				top: var(--win-border-width);
				height: var(--win-icon-innerWidth);
				width: var(--win-icon-innerWidth);
				cursor: pointer;
			  }

			  #minbut:active {
				background-color: var(--box-color);
				border-left: 1px solid var(--box-border-dark);
				border-top: 1px solid var(--box-border-dark);
				border-right: 1px solid var(--box-border-light);
				border-bottom: 1px solid var(--box-border-light);
			  }

			  #minbut-icon {
				position: relative;
				top: 38.889%;
				height:11.111%;
				left:38.889%;
				width: 11.111%;
			  }

			  #maxbut {
				position: absolute;
				left: calc(var(--win-border-seg-offset-beg) + var(--win-border-seg-width) + 2 * var(--win-box-border));
				top: var(--win-border-width);
				height: var(--win-icon-innerWidth);
				width: var(--win-icon-innerWidth);
				cursor: pointer;
			  }

			  #maxbut:active {
				background-color: var(--box-color);
				border-left: 1px solid var(--box-border-dark);
				border-top: 1px solid var(--box-border-dark);
				border-right: 1px solid var(--box-border-light);
				border-bottom: 1px solid var(--box-border-light);
			  }

			  #maxbut-icon {
				position: relative;
				top: 15%;
				height:55.556%;
				left: 15%;
				width: 55.556%;
			  }

			  #border-left {
				position: absolute;
				z-index:999;
				left: 0%;
				top: var(--win-cc-width);
				height:calc(100% - 2* var(--win-border-width));
				width:var(--win-border-innerWidth);
				border-top:none;border-bottom:none;
			  }

			  #border-right {
				position: absolute;
				z-index:999;
				left: calc(100% - var(--win-border-width));
				top: var(--win-cc-width);
				height:calc(100% - 2* var(--win-border-width));
				width:var(--win-border-innerWidth);
				border-top:none;border-bottom:none;
			  }

			  #border-top {
				position: absolute;
				z-index:999;
				left: var(--win-cc-width);
				top: 0px;
				height:var(--win-border-innerWidth);
				width:calc(100% - 2* var(--win-border-width));
				border-left:none;border-right:none;
			  }

			  #border-bottom {
				position: absolute;
				z-index:999;
				left: var(--win-cc-width);
				top: calc(100% - var(--win-border-width));
				height:var(--win-border-innerWidth);
				width:calc(100% - 2* var(--win-border-width));
				border-left:none;border-right:none;
			  }

			  #border-inner-left {
				position: absolute;
				z-index:999;
				left: 0%;
				top: var(--win-border-seg-offset-beg);
				height:var(--win-border-seg-width);
				width:var(--win-border-innerWidth);
			  }

			  #border-inner-right {
				position: absolute;
				z-index:999;
				left: calc(100% - var(--win-border-width));
				top: var(--win-border-seg-offset-beg);
				height:var(--win-border-seg-width);
				width:var(--win-border-innerWidth);
			  }

			  #border-inner-top {
				position: absolute;
				z-index:999;
				left: var(--win-border-seg-offset-beg);
				top: 0px;
				height:var(--win-border-innerWidth);
				width:var(--win-border-seg-width);
			  }

			  #border-inner-bottom {
				position: absolute;
				z-index:999;
				left: var(--win-border-seg-offset-beg);
				top: calc(100% - var(--win-border-width));
				height:var(--win-border-innerWidth);
				width:var(--win-border-seg-width);
			  }


			  div #c-ulc {
				position: absolute;
				z-index:999;
				left:0;top:0;width:var(--win-cc-width);height:var(--win-cc-width);
				border-right:none;border-bottom:none;
			  }
			  div #c-ull {
				position: absolute;
				z-index:999;
				left:0;top:var(--win-cc-width);width:var(--win-border-innerWidth);height:var(--win-icon-size);
				border-top-style:none;
			  }
			  div #c-ulr {
				position: absolute;
				z-index:999;
				left:var(--win-cc-width);top:0px;
				width:var(--win-icon-size);height:var(--win-border-innerWidth);
				border-left-style:none;
			  }

			  div #c-urc {
				position: absolute;
				z-index:999;
				left:calc(100% - var(--win-border-width));top:0;width:var(--win-cc-width);height:var(--win-cc-width);
				border-left-style:none;border-bottom-style:none;
			  }
			  div #c-url {
				position: absolute;
				z-index:999;
				left:calc(100% - var(--win-border-width));top:var(--win-cc-width);width:var(--win-border-innerWidth);height:var(--win-icon-size);
				border-top-style:none;
			  }
			  div #c-urr {
				position: absolute;
				z-index:999;
				left:calc(100% - var(--win-cc-width) - var(--win-icon-size) - var(--win-box-border));top:0px;
				width:var(--win-icon-size);height:var(--win-border-innerWidth);
				border-right-style:none;
			  }


			  div #c-blc {
				position: absolute;
				z-index:999;
				left:0;top:calc(100% - var(--win-cc-width));
				width:var(--win-cc-width);height:calc(var(--win-cc-width) - var(--win-box-border));
				border-right-style:none;border-top-style:none;
			  }
			  div #c-bll {
				position: absolute;
				z-index:999;
				left:0;top:calc(100% - var(--win-cc-width) - var(--win-icon-size) - var(--win-box-border));width:var(--win-border-innerWidth);height:var(--win-icon-size);
				border-bottom-style:none;
			  }
			  div #c-blr {
				position: absolute;
				z-index:999;
				left:var(--win-cc-width);top:calc(100% - var(--win-cc-width) - var(--win-box-border));
				width:var(--win-icon-size);height:var(--win-border-innerWidth);
				border-left-style:none;
			  }

			  div #c-brc {
				position: absolute;
				z-index:999;
				left:calc(100% - var(--win-border-width));top:calc(100% - var(--win-cc-width));
				width:var(--win-cc-width);height:calc(var(--win-cc-width) - var(--win-box-border));
				border-left-style:none;border-top-style:none;
			  }
			  div #c-brl {
				position: absolute;
				z-index:999;
				left:calc(100% - var(--win-border-width));top:calc(100% - var(--win-cc-width) - var(--win-icon-size) - var(--win-box-border));
				width:var(--win-border-innerWidth);height:var(--win-icon-size);
				border-bottom-style:none;
			  }
			  div #c-brr {
				position: absolute;
				z-index:999;
				left:calc(100% - var(--win-cc-width) - var(--win-icon-size) - var(--win-box-border));top:calc(100% - var(--win-cc-width) - var(--win-box-border));
				width:var(--win-icon-size);height:var(--win-border-innerWidth);
				border-right-style:none;
			  }

			  #cde-content {
				display:block;
				position:absolute;
				left:calc(var(--win-border-width));
				width:calc(100% - 2 * var(--win-border-width));
				top:calc(var(--win-border-width)  + var(--win-icon-size));
				height:calc(100% - 2 * var(--win-border-width) - var(--win-icon-size));
				-webkit-app-region:no-drag;
			  }

			`
		  ]
	}
}

declare global {
	interface HTMLElementTagNameMap {
	  'cde-window': CdeWindow;
	}
  }
