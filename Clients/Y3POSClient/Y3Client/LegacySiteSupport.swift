import Foundation

struct FramePane: Identifiable {
    let path: [Int]
    let title: String
    var id: String { path.map(String.init).joined(separator: ".") }
}

enum LegacySiteSupport {
    // Runs inside each document, never through a native message or credentials bridge.
    static let viewportAndTouch = #"""
    (() => {
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      const exportDocument = location.origin === 'https://adidas-y3.poscmcloud.jp:7705' &&
        location.pathname === '/dataspider/trigger/hanbai.asp';
      if ((location.origin !== origin && !exportDocument) || !document.documentElement) return;
      const root = document.documentElement;
      root.setAttribute('data-y3client-phone', '');
      const head = document.head;
      if (head && !head.querySelector('meta[name="viewport"]')) {
        const viewport = document.createElement('meta');
        viewport.name = 'viewport';
        viewport.content = 'width=device-width, initial-scale=1';
        head.appendChild(viewport);
      }
      if (head && !document.getElementById('y3client-touch-style')) {
        const style = document.createElement('style');
        style.id = 'y3client-touch-style';
        style.textContent = `
          html[data-y3client-phone] { -webkit-text-size-adjust: 100%; }
          html[data-y3client-phone] input:not([type="hidden" i]),
          html[data-y3client-phone] select,
          html[data-y3client-phone] textarea,
          html[data-y3client-phone] button {
            font-size: 16px !important; min-height: 44px; box-sizing: border-box;
          }
          html[data-y3client-phone] input[type="submit" i],
          html[data-y3client-phone] input[type="reset" i],
          html[data-y3client-phone] input[type="button" i],
          html[data-y3client-phone] button {
            min-width: 44px; padding: 8px 12px;
          }
          html[data-y3client-phone] input[name*="YYYYMMDD" i] {
            width: 9ch !important; min-width: 9ch; padding-inline: 3px;
          }
          html[data-y3client-phone] input:focus,
          html[data-y3client-phone] select:focus,
          html[data-y3client-phone] textarea:focus { scroll-margin-block: 88px; }
          html[data-y3client-phone] form[data-y3client-search] { max-width: 100%; }
          html[data-y3client-phone] table[data-y3client-search-table] {
            display: block; width: 100% !important; max-width: 100%; box-sizing: border-box;
          }
          html[data-y3client-phone] table[data-y3client-search-table] > tbody { display: block; max-width: 100%; }
          html[data-y3client-phone] table[data-y3client-search-table] > tbody > tr {
            display: flex; flex-wrap: wrap; align-items: center; gap: 4px 8px;
            width: 100%; box-sizing: border-box;
          }
          html[data-y3client-phone] table[data-y3client-search-table] > tbody > tr > td {
            display: block; flex: 0 1 auto; width: auto !important; max-width: 100%;
            white-space: normal !important; box-sizing: border-box;
          }
          html[data-y3client-menu] a,
          html[data-y3client-export] a[download] {
            display: inline-block; font-size: 16px !important; line-height: 1.4;
            min-height: 44px; box-sizing: border-box; padding: 10px 6px;
          }
          html[data-y3client-phone] iframe[name="fraHinbanSearch"] {
            max-width: calc(100vw - 16px);
          }
          html[data-y3client-stock] #layer0 {
            left: 8px !important; right: 8px !important; width: auto !important;
            max-width: calc(100vw - 16px); height: min(65vh, 500px) !important;
          }
          html[data-y3client-stock] iframe[name="fraHinbanSearch"] {
            width: 100% !important; height: 100% !important;
          }
        `;
        head.appendChild(style);
      }
      if (/\/scripts\/verona\/menu\//i.test(location.pathname)) {
        root.setAttribute('data-y3client-menu', '');
      }
      if (/\/prtz011_1\.asp$/i.test(location.pathname)) root.setAttribute('data-y3client-stock', '');
      // Form elements may be outside FORM in these legacy tables; use their existing form ownership.
      for (const form of document.forms) {
        const fields = Array.from(form.elements).filter(element => element.tagName === 'INPUT' &&
          element.type !== 'hidden' && (['text', 'date', 'search'].includes(element.type) || /YYYYMMDD/i.test(element.name)));
        if (!fields.length) continue;
        form.setAttribute('data-y3client-search', '');
        for (const field of fields) {
          const table = field.closest('table');
          if (!table || table.querySelectorAll('tr').length > 8) continue;
          let clonedResult = false;
          for (let ancestor = table; ancestor; ancestor = ancestor.parentElement) {
            if (/^D_.*_[HB]$/.test(ancestor.id)) { clonedResult = true; break; }
          }
          if (!clonedResult) table.setAttribute('data-y3client-search-table', '');
        }
      }
      if (exportDocument) {
        root.setAttribute('data-y3client-export', '');
        for (const anchor of document.querySelectorAll('a[href]')) {
          const url = new URL(anchor.href, location.href);
          if (url.origin !== origin || !/^\/scripts\/verona\/download\/[^/]+\.(csv|xls)$/i.test(url.pathname)) continue;
          anchor.setAttribute('download', '');
          if (/右クリック/.test(anchor.textContent)) {
            anchor.textContent = /\.csv$/i.test(url.pathname) ? 'CSVを保存' : 'Excelを保存';
          }
        }
      }
      // Only the observed fixed-height search frame is enlarged. Report grids keep their ratios.
      for (const frameset of document.querySelectorAll('frameset[rows]')) {
        const rows = frameset.getAttribute('rows').split(',');
        const first = Array.from(frameset.children).find(node => node.tagName === 'FRAME');
        if (rows[0].trim() === '115' && first && /(?:_1_1|condition|search)$/i.test(first.name)) {
          rows[0] = '180';
          frameset.setAttribute('rows', rows.join(','));
        }
      }
    })();
    """#

    // Reports only integer frame paths and a structural role, never contents, URLs, or form data.
    static let discoverFrames = #"""
    (() => {
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      const trusted = win => { try { return win.location.origin === origin; } catch (_) { return false; } };
      if (!trusted(window) || !document.querySelector('frameset')) return [];
      const panes = [];
      const walk = (win, path, condition) => {
        if (!trusted(win) || path.length > 8 || panes.length >= 12) return;
        let frames = [];
        try {
          frames = Array.from(win.document.querySelectorAll('frame')).filter(frame => frame.contentWindow);
        } catch (_) { return; }
        if (frames.length) {
          for (const element of frames) {
            let index = -1;
            for (let i = 0; i < Math.min(win.frames.length, 64); i++) {
              if (win.frames[i] === element.contentWindow) { index = i; break; }
            }
            if (index < 0) continue;
            // The export service has another port. Recognize its parent-owned FRAME without inspecting it.
            if (/\/dstz210_2\.asp$/i.test(win.location.pathname) && element.name === 'dstz210_2_2') {
              panes.push({ path: path.concat(index), kind: 'export' });
              if (panes.length >= 12) return;
              continue;
            }
            walk(element.contentWindow, path.concat(index), condition || /(?:_1_1|condition|search)$/i.test(element.name));
          }
          return;
        }
        if (!path.length) return;
        try {
          if (/dummy|blank|empty/i.test(win.name)) return;
          const body = win.document.body;
          if (!body || (!body.textContent.trim() && !body.querySelector('form,table,a,input,select,textarea,img'))) return;
          const tableRows = body.querySelectorAll('table tr').length;
          const tableCells = body.querySelectorAll('table td,table th').length;
          const controls = body.querySelector('input:not([type="hidden" i]),select,textarea,button');
          const searchFields = body.querySelector('input[name*="YYYYMMDD" i]:not([type="hidden" i]),input[type="text" i],input[type="date" i],input[type="search" i],textarea');
          const kind = (searchFields || (condition && controls && body.querySelector('form'))) ? 'condition' :
            (tableRows >= 5 || tableCells >= 20) ? 'result' : controls ? 'controls' : 'navigation';
          panes.push({ path, kind });
        } catch (_) {}
      };
      walk(window, [], false);
      return panes;
    })();
    """#

    // The only argument is a validated integer path or null. Existing frame nodes are retained.
    static let frameFocus = #"""
    (path) => {
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      const trusted = win => { try { return win.location.origin === origin; } catch (_) { return false; } };
      if (!trusted(window) || !document.querySelector('frameset')) return false;
      if (path !== null && (!Array.isArray(path) || !path.length || path.length > 8 ||
          path.some(index => !Number.isInteger(index) || index < 0 || index >= 64))) return false;
      const changes = [];
      let focusedWindow = null;
      if (path !== null) {
        let win = window;
        for (let position = 0; position < path.length; position++) {
          const index = path[position];
          if (index >= win.frames.length) return false;
          const child = win.frames[index];
          // Resolve the FRAME in the trusted parent rather than reading a cross-origin frameElement.
          let branch = Array.from(win.document.querySelectorAll('frame')).find(element => element.contentWindow === child);
          if (!branch || branch.tagName !== 'FRAME' || branch.ownerDocument !== win.document) return false;
          const opaqueExport = position === path.length - 1 && /\/dstz210_2\.asp$/i.test(win.location.pathname) &&
            branch.name === 'dstz210_2_2';
          if (!trusted(child) && !opaqueExport) return false;
          for (let parent = branch.parentElement; parent && parent.tagName === 'FRAMESET'; parent = branch.parentElement) {
            const children = Array.from(parent.children).filter(node => /^(FRAME|FRAMESET)$/.test(node.tagName));
            const selected = children.indexOf(branch);
            if (selected < 0) return false;
            changes.push({ element: parent, count: children.length, selected });
            branch = parent;
          }
          win = child;
        }
        if (trusted(win)) focusedWindow = win;
      }
      const state = window.__y3ClientFrameLayout || { originals: [] };
      for (const saved of state.originals) {
        if (!saved.element.isConnected) continue;
        for (const name of ['rows', 'cols']) {
          if (saved[name] === null) saved.element.removeAttribute(name);
          else saved.element.setAttribute(name, saved[name]);
        }
      }
      state.originals = [];
      const seen = new Set();
      for (const change of changes) {
        const element = change.element;
        if (seen.has(element)) continue;
        seen.add(element);
        state.originals.push({ element, rows: element.getAttribute('rows'), cols: element.getAttribute('cols') });
        for (const name of ['rows', 'cols']) {
          if (!element.hasAttribute(name)) continue;
          element.setAttribute(name, Array.from({ length: change.count }, (_, index) => index === change.selected ? '*' : '0').join(','));
        }
      }
      window.__y3ClientFrameLayout = state;
      if (focusedWindow) requestAnimationFrame(() => {
        if (trusted(focusedWindow)) { try { focusedWindow.dispatchEvent(new Event('resize')); } catch (_) {} }
      });
      return true;
    }
    """#

    static func focusScript(path: [Int]?) -> String {
        let argument: String
        if let path, !path.isEmpty, path.count <= 8, path.allSatisfy({ (0 ..< 64).contains($0) }) {
            argument = "[" + path.map(String.init).joined(separator: ",") + "]"
        } else if path == nil { argument = "null" }
        else { return "false" }
        return "(" + frameFocus + ")(" + argument + ")"
    }

    // Click the site's own link, retaining its onclick handler, frame target, and transition rules.
    static let siteHome = #"""
    (() => {
      const origin = 'https://adidas-y3.poscmcloud.jp:15505';
      const path = '/scripts/verona/menu/metz010_1.asp';
      const trusted = win => { try { return win.location.origin === origin; } catch (_) { return false; } };
      if (!trusted(window)) return false;
      if (location.pathname === path) return true;
      const find = (win, depth) => {
        if (depth > 8 || !trusted(win)) return null;
        try {
          for (const anchor of win.document.querySelectorAll('a[href]')) {
            const url = new URL(anchor.href, win.location.href);
            if (url.origin === origin && url.pathname === path && !url.username && !url.password &&
                (win === window || anchor.target.toLowerCase() === '_top')) return anchor;
          }
          for (let i = 0; i < Math.min(win.frames.length, 64); i++) {
            const anchor = find(win.frames[i], depth + 1);
            if (anchor) return anchor;
          }
        } catch (_) {}
        return null;
      };
      const anchor = find(window, 0);
      if (!anchor) return false;
      anchor.click();
      return true;
    })();
    """#
}
