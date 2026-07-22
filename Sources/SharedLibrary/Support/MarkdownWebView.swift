import AppKit
import Down
import SwiftUI
import WebKit

private enum MarkdownAppearanceCSS {
    static let lightVariables = """
          --ink: rgba(29, 29, 27, 0.94);
          --heading: rgba(25, 25, 24, 0.96);
          --rule: rgba(55, 55, 51, 0.09);
          --link: rgb(56, 56, 52);
          --link-decoration: rgba(56, 56, 52, 0.42);
          --hairline-soft: rgba(36, 36, 34, 0.13);
          --hairline: rgba(36, 36, 34, 0.18);
          --hairline-strong: rgba(36, 36, 34, 0.28);
          --muted-ink: rgba(38, 38, 36, 0.72);
          --code-fill: rgba(65, 65, 61, 0.08);
          --code-fill-soft: rgba(65, 65, 61, 0.07);
          --code-ink: rgba(25, 25, 24, 0.94);
          --error-ink: rgba(38, 38, 36, 0.78);
    """

    static let darkVariables = """
          --ink: rgba(232, 230, 220, 0.93);
          --heading: rgba(245, 242, 232, 0.96);
          --rule: rgba(220, 217, 205, 0.10);
          --link: rgb(211, 209, 199);
          --link-decoration: rgba(211, 209, 199, 0.42);
          --hairline-soft: rgba(224, 221, 209, 0.13);
          --hairline: rgba(224, 221, 209, 0.18);
          --hairline-strong: rgba(224, 221, 209, 0.28);
          --muted-ink: rgba(205, 202, 192, 0.74);
          --code-fill: rgba(235, 232, 220, 0.08);
          --code-fill-soft: rgba(235, 232, 220, 0.07);
          --code-ink: rgba(240, 237, 226, 0.94);
          --error-ink: rgba(213, 210, 200, 0.80);
    """
}

struct MarkdownWebView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    var isDarkMode = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.appearance = NSAppearance(named: isDarkMode ? .darkAqua : .aqua)
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.appearance = NSAppearance(named: isDarkMode ? .darkAqua : .aqua)

        guard context.coordinator.renderedMarkdown != markdown ||
              context.coordinator.renderedBaseURL != baseURL else {
            return
        }
        guard context.coordinator.pendingMarkdown != markdown ||
              context.coordinator.pendingBaseURL != baseURL else {
            return
        }

        context.coordinator.renderGeneration += 1
        context.coordinator.pendingMarkdown = markdown
        context.coordinator.pendingBaseURL = baseURL

        let generation = context.coordinator.renderGeneration
        let coordinator = context.coordinator
        let markdown = markdown
        let baseURL = baseURL
        weak var weakWebView = webView

        DispatchQueue.global(qos: .userInitiated).async {
            let pageHTML = Self.pageHTML(for: markdown)

            DispatchQueue.main.async {
                guard let webView = weakWebView,
                      coordinator.renderGeneration == generation else {
                    return
                }

                coordinator.pendingMarkdown = nil
                coordinator.pendingBaseURL = nil
                coordinator.renderedMarkdown = markdown
                coordinator.renderedBaseURL = baseURL
                webView.loadHTMLString(pageHTML, baseURL: baseURL)
            }
        }
    }

    private static func pageHTML(for markdown: String) -> String {
        let bodyHTML: String

        do {
            let options: DownOptions = [.safe, .smart, .validateUTF8]
            bodyHTML = try Down(markdownString: markdown).toHTML(options)
        } catch {
            bodyHTML = "<pre class=\"render-error\">\(escapedHTML(markdown))</pre>"
        }

        return """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: file: https: http:; style-src 'unsafe-inline';">
        <style>
        :root {
          color-scheme: light dark;
          background: transparent;
        \(MarkdownAppearanceCSS.lightVariables)
        }

        @media (prefers-color-scheme: dark) {
          :root {
        \(MarkdownAppearanceCSS.darkVariables)
          }
        }

        html,
        body {
          margin: 0;
          min-height: 100%;
          background: transparent;
        }

        * {
          box-sizing: border-box;
        }

        body {
          padding: 46px 40px 34px;
          color: var(--ink);
          font: 19px/32px "New York", "Iowan Old Style", Charter, Georgia, serif;
          -webkit-font-smoothing: antialiased;
          overflow-wrap: anywhere;
          background-image: linear-gradient(
            to bottom,
            transparent 0,
            transparent 31px,
            var(--rule) 31px,
            var(--rule) 32px
          );
          background-repeat: repeat;
          background-size: 100% 32px;
          background-position: 0 43px;
        }

        body > :first-child {
          margin-top: 0;
        }

        body > :last-child {
          margin-bottom: 0;
        }

        h1,
        h2,
        h3,
        h4,
        h5,
        h6 {
          margin: 32px 0;
          color: var(--heading);
          font-weight: 700;
          line-height: 32px;
          position: relative;
          top: -2px;
        }

        h1 {
          padding: 0;
          font-size: 28px;
        }

        h2 {
          padding: 0;
          font-size: 23px;
        }

        h3 {
          font-size: 19px;
        }

        p,
        ul,
        ol,
        blockquote,
        pre,
        table {
          margin: 0 0 32px;
        }

        ul,
        ol {
          padding-left: 1.45em;
        }

        li + li {
          margin-top: 0;
        }

        a {
          color: var(--link);
          text-decoration-color: var(--link-decoration);
          text-underline-offset: 0.14em;
        }

        hr {
          margin: 32px 0;
          border: 0;
          border-top: 1px solid var(--hairline-strong);
        }

        blockquote {
          padding: 0 0 0 1em;
          border-left: 3px solid var(--hairline-strong);
          color: var(--muted-ink);
        }

        code,
        pre {
          font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
          font-size: 0.92em;
        }

        code {
          padding: 0.12em 0.36em;
          border: 1px solid var(--hairline-soft);
          border-radius: 5px;
          background: var(--code-fill);
          color: var(--code-ink);
          white-space: break-spaces;
        }

        pre {
          padding: 15px 14px;
          border: 1px solid var(--hairline-soft);
          border-radius: 8px;
          background: var(--code-fill-soft);
          line-height: 32px;
          overflow: auto;
        }

        pre code {
          padding: 0;
          border: 0;
          border-radius: 0;
          background: transparent;
          white-space: pre;
        }

        img {
          max-width: 100%;
          height: auto;
          border-radius: 6px;
        }

        table {
          width: 100%;
          border-collapse: collapse;
          overflow: hidden;
        }

        th,
        td {
          padding: 7px 9px;
          border: 1px solid var(--hairline);
          vertical-align: top;
        }

        th {
          background: var(--code-fill);
          font-weight: 650;
        }

        .render-error {
          color: var(--error-ink);
        }
        </style>
        </head>
        <body>
        \(bodyHTML)
        </body>
        </html>
        """
    }

    private static func escapedHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var renderedMarkdown: String?
        var renderedBaseURL: URL?
        var pendingMarkdown: String?
        var pendingBaseURL: URL?
        var renderGeneration = 0

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.scrollTo(0, 0);")
        }
    }
}

struct EditableMarkdownWebView: NSViewRepresentable {
    @Binding var markdown: String
    let baseURL: URL?
    var focusRequest = 0
    var isDarkMode = false

    func makeCoordinator() -> Coordinator {
        Coordinator(markdown: $markdown)
    }

    func makeNSView(context: Context) -> WKWebView {
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "editor")

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.appearance = NSAppearance(named: isDarkMode ? .darkAqua : .aqua)
        context.coordinator.webView = webView
        context.coordinator.focusRequest = focusRequest
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.markdown = $markdown
        webView.appearance = NSAppearance(named: isDarkMode ? .darkAqua : .aqua)

        if context.coordinator.renderedMarkdown != markdown ||
            context.coordinator.renderedBaseURL != baseURL {
            context.coordinator.renderedMarkdown = markdown
            context.coordinator.renderedBaseURL = baseURL
            webView.loadHTMLString(Self.pageHTML(for: markdown), baseURL: baseURL)
        }

        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async {
                webView.evaluateJavaScript("window.focusEditor && window.focusEditor();")
            }
        }
    }

    private static func pageHTML(for markdown: String) -> String {
        let bodyHTML: String

        do {
            let options: DownOptions = [.safe, .smart, .validateUTF8]
            bodyHTML = try Down(markdownString: markdown).toHTML(options)
        } catch {
            bodyHTML = "<pre class=\"render-error\">\(escapedHTML(markdown))</pre>"
        }

        return #"""
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data: file: https: http:; style-src 'unsafe-inline'; script-src 'unsafe-inline';">
        <style>
        :root {
          color-scheme: light dark;
          background: transparent;
        \#(MarkdownAppearanceCSS.lightVariables)
        }

        @media (prefers-color-scheme: dark) {
          :root {
        \#(MarkdownAppearanceCSS.darkVariables)
          }
        }

        html,
        body {
          margin: 0;
          min-height: 100%;
          background: transparent;
        }

        * {
          box-sizing: border-box;
        }

        body {
          padding: 46px 40px 34px;
          color: var(--ink);
          font: 19px/32px "New York", "Iowan Old Style", Charter, Georgia, serif;
          -webkit-font-smoothing: antialiased;
          overflow-wrap: anywhere;
          outline: none;
          caret-color: var(--heading);
          background-image: linear-gradient(
            to bottom,
            transparent 0,
            transparent 31px,
            var(--rule) 31px,
            var(--rule) 32px
          );
          background-repeat: repeat;
          background-size: 100% 32px;
          background-position: 0 43px;
        }

        body:focus {
          outline: none;
        }

        body > :first-child {
          margin-top: 0;
        }

        body > :last-child {
          margin-bottom: 0;
        }

        h1,
        h2,
        h3,
        h4,
        h5,
        h6 {
          margin: 32px 0;
          color: var(--heading);
          font-weight: 700;
          line-height: 32px;
          position: relative;
          top: -2px;
        }

        h1 {
          padding: 0;
          font-size: 28px;
        }

        h2 {
          padding: 0;
          font-size: 23px;
        }

        h3 {
          font-size: 19px;
        }

        p,
        ul,
        ol,
        blockquote,
        pre,
        table {
          margin: 0 0 32px;
        }

        ul,
        ol {
          padding-left: 1.45em;
        }

        li + li {
          margin-top: 0;
        }

        a {
          color: var(--link);
          text-decoration-color: var(--link-decoration);
          text-underline-offset: 0.14em;
        }

        hr {
          margin: 32px 0;
          border: 0;
          border-top: 1px solid var(--hairline-strong);
        }

        blockquote {
          padding: 0 0 0 1em;
          border-left: 3px solid var(--hairline-strong);
          color: var(--muted-ink);
        }

        code,
        pre {
          font-family: ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
          font-size: 0.92em;
        }

        code {
          padding: 0.12em 0.36em;
          border: 1px solid var(--hairline-soft);
          border-radius: 5px;
          background: var(--code-fill);
          color: var(--code-ink);
          white-space: break-spaces;
        }

        pre {
          padding: 15px 14px;
          border: 1px solid var(--hairline-soft);
          border-radius: 8px;
          background: var(--code-fill-soft);
          line-height: 32px;
          overflow: auto;
        }

        pre code {
          padding: 0;
          border: 0;
          border-radius: 0;
          background: transparent;
          white-space: pre;
        }

        img {
          max-width: 100%;
          height: auto;
          border-radius: 6px;
        }

        table {
          width: 100%;
          border-collapse: collapse;
          overflow: hidden;
        }

        th,
        td {
          padding: 7px 9px;
          border: 1px solid var(--hairline);
          vertical-align: top;
        }

        th {
          background: var(--code-fill);
          font-weight: 650;
        }

        .render-error {
          color: var(--error-ink);
        }
        </style>
        <script>
        (function () {
          function text(node) {
            return (node.textContent || '').replace(/\u00a0/g, ' ');
          }

          function escapeInline(value) {
            return value.replace(/\u00a0/g, ' ');
          }

          function inlineMarkdown(node) {
            if (!node) return '';
            if (node.nodeType === Node.TEXT_NODE) return escapeInline(node.nodeValue || '');
            if (node.nodeType !== Node.ELEMENT_NODE) return '';

            var tag = node.tagName.toLowerCase();
            if (tag === 'br') return '\n';
            if (tag === 'code' && node.parentElement && node.parentElement.tagName.toLowerCase() !== 'pre') {
              return '`' + text(node).replace(/`/g, '\\`') + '`';
            }
            if (tag === 'strong' || tag === 'b') return '**' + childInline(node) + '**';
            if (tag === 'em' || tag === 'i') return '*' + childInline(node) + '*';
            if (tag === 'a') {
              var href = node.getAttribute('href') || '';
              var label = childInline(node) || href;
              return href ? '[' + label + '](' + href + ')' : label;
            }
            if (tag === 'img') {
              return '![' + (node.getAttribute('alt') || '') + '](' + (node.getAttribute('src') || '') + ')';
            }
            return childInline(node);
          }

          function childInline(node) {
            return Array.from(node.childNodes).map(inlineMarkdown).join('');
          }

          function listMarkdown(node, ordered) {
            return Array.from(node.children).filter(function (child) {
              return child.tagName && child.tagName.toLowerCase() === 'li';
            }).map(function (li, index) {
              var prefix = ordered ? (index + 1) + '. ' : '- ';
              var value = childInline(li).trim();
              return prefix + value.replace(/\n/g, '\n  ');
            }).join('\n');
          }

          function blockMarkdown(node) {
            if (node.nodeType === Node.TEXT_NODE) return escapeInline(node.nodeValue || '').trim();
            if (node.nodeType !== Node.ELEMENT_NODE) return '';

            var tag = node.tagName.toLowerCase();
            if (/^h[1-6]$/.test(tag)) {
              return '#'.repeat(Number(tag.substring(1))) + ' ' + childInline(node).trim();
            }
            if (tag === 'p' || tag === 'div') return childInline(node).trim();
            if (tag === 'ul') return listMarkdown(node, false);
            if (tag === 'ol') return listMarkdown(node, true);
            if (tag === 'script' || tag === 'style') return '';
            if (tag === 'blockquote') {
              return childrenMarkdown(node).split('\n').map(function (line) {
                return line ? '> ' + line : '>';
              }).join('\n');
            }
            if (tag === 'pre') return '```\n' + text(node).replace(/\n$/, '') + '\n```';
            if (tag === 'hr') return '---';
            if (tag === 'table') return text(node).trim();
            return childInline(node).trim();
          }

          function childrenMarkdown(node) {
            return Array.from(node.childNodes).map(blockMarkdown).filter(function (value) {
              return value.length > 0;
            }).join('\n\n');
          }

          function toMarkdown() {
            return childrenMarkdown(document.body).replace(/\n{3,}/g, '\n\n').trim();
          }

          var pending = null;
          function postChange() {
            if (pending) window.clearTimeout(pending);
            pending = window.setTimeout(function () {
              pending = null;
              window.webkit.messageHandlers.editor.postMessage(toMarkdown());
            }, 120);
          }

          document.body.addEventListener('input', postChange);
          window.focusEditor = function () {
            document.body.focus();
          };
        }());
        </script>
        </head>
        <body contenteditable="true" spellcheck="true">
        \#(bodyHTML)
        </body>
        </html>
        """#
    }

    private static func escapedHTML(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var markdown: Binding<String>
        weak var webView: WKWebView?
        var renderedMarkdown: String?
        var renderedBaseURL: URL?
        var focusRequest = 0

        init(markdown: Binding<String>) {
            self.markdown = markdown
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "editor",
                  let updatedMarkdown = message.body as? String else {
                return
            }
            renderedMarkdown = updatedMarkdown
            markdown.wrappedValue = updatedMarkdown
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("window.scrollTo(0, 0);")
        }
    }
}
