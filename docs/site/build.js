/*
 * Builds the documentation site from submodules/ExteraPluginKit/docs/API.md.
 *
 * The reference is written once, as Markdown, next to the code it describes; the
 * site is generated so the two cannot drift. This implements only the subset of
 * Markdown that file actually uses — headings, fenced code, GFM tables, nested
 * lists, blockquotes, rules, inline code/bold/italic/links — because pulling in a
 * general parser would add a dependency and a lockfile for a page whose source is
 * one file written in a known style.
 *
 * Usage: node docs/site/build.js [output directory]
 * Default output is docs/site/public, which is what the deployment workflow
 * uploads.
 */
const fs = require('fs');
const path = require('path');

const here = __dirname;
const repo = path.resolve(here, '..', '..');
const SOURCE = path.join(repo, 'submodules', 'ExteraPluginKit', 'docs', 'API.md');
const OUT = process.argv[2] ? path.resolve(process.argv[2]) : path.join(here, 'public');

// The reference's own table of contents duplicates what the sidebar does, and
// its anchors are relative to the page anyway. Dropping it keeps one way to
// navigate.
const CONTENTS_HEADING = 'contents';

function escapeHTML(text) {
    return text
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;');
}

// GitHub's own heading anchor: lowercase, drop everything that is not a letter,
// a digit, a combining mark, `_` or `-`, then spaces become `-`.
function slug(text) {
    return text
        .trim()
        .toLowerCase()
        .replace(/[^\p{L}\p{N}\p{M}\s_-]/gu, '')
        .replace(/\s/g, '-');
}

// Splits a table row on `|`, ignoring pipes inside code spans.
function splitRow(line) {
    let text = line.trim();
    if (text.startsWith('|')) text = text.slice(1);
    if (text.endsWith('|')) text = text.slice(0, -1);
    const cells = [];
    let current = '';
    let inCode = false;
    for (let i = 0; i < text.length; i++) {
        const ch = text[i];
        if (ch === '\\' && text[i + 1] === '|') { current += '|'; i++; continue; }
        if (ch === '`') { inCode = !inCode; current += ch; continue; }
        if (ch === '|' && !inCode) { cells.push(current.trim()); current = ''; continue; }
        current += ch;
    }
    cells.push(current.trim());
    return cells;
}

function inline(text) {
    const codes = [];
    // Code spans are pulled out first so their contents are not treated as
    // emphasis or a link, and put back at the end.
    let work = text.replace(/`([^`]+)`/g, (_, code) => {
        codes.push(code);
        return '\u0000' + (codes.length - 1) + '\u0000';
    });
    work = escapeHTML(work);
    work = work.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_, label, href) => {
        const external = /^https?:/i.test(href);
        const attrs = external ? ' target="_blank" rel="noopener"' : '';
        return `<a href="${href}"${attrs}>${label}</a>`;
    });
    work = work.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    work = work.replace(/(^|[\s(])\*([^*\n]+)\*/g, '$1<em>$2</em>');
    work = work.replace(/(^|[\s(])_([^_\n]+)_/g, '$1<em>$2</em>');
    work = work.replace(/\u0000(\d+)\u0000/g, (_, index) => `<code>${escapeHTML(codes[Number(index)])}</code>`);
    return work;
}

function renderList(lines, start) {
    const first = lines[start].match(/^(\s*)([-*]|\d+\.)\s+/);
    const baseIndent = first[1].length;
    const orderedList = /^\d+\.$/.test(first[2]);
    const items = [];
    let index = start;

    while (index < lines.length) {
        const line = lines[index];
        const match = line.match(/^(\s*)([-*]|\d+\.)\s+(.*)$/);
        if (!match) {
            // A continuation line belongs to the item above it when it is
            // indented past the marker.
            if (items.length > 0 && line.trim() !== '' && /^\s{2,}/.test(line)) {
                items[items.length - 1].text += ' ' + line.trim();
                index++;
                continue;
            }
            break;
        }
        if (match[1].length < baseIndent) break;
        if (match[1].length > baseIndent) {
            const nested = renderList(lines, index);
            items[items.length - 1].text += '\n' + nested.html;
            index = nested.next;
            continue;
        }
        items.push({ text: match[3] });
        index++;
    }

    const tag = orderedList ? 'ol' : 'ul';
    let html = `<${tag}>`;
    for (const item of items) {
        const parts = item.text.split('\n');
        const body = inline(parts[0]);
        const rest = parts.slice(1).join('\n');
        html += `<li>${body}${rest}</li>`;
    }
    html += `</${tag}>`;
    return { html, next: index };
}

function render(markdown) {
    const lines = markdown.replace(/\r\n/g, '\n').split('\n');
    const out = [];
    const headings = [];
    let index = 0;

    while (index < lines.length) {
        const line = lines[index];

        const fence = line.match(/^```(\S*)\s*$/);
        if (fence) {
            const language = fence[1] || '';
            const body = [];
            index++;
            while (index < lines.length && !/^```\s*$/.test(lines[index])) {
                body.push(lines[index]);
                index++;
            }
            index++;
            const label = language ? `<span class="code-lang">${escapeHTML(language)}</span>` : '';
            out.push(`<div class="code-block">${label}<pre><code class="language-${escapeHTML(language)}">${escapeHTML(body.join('\n'))}</code></pre></div>`);
            continue;
        }

        if (/^\s*---+\s*$/.test(line)) {
            out.push('<hr>');
            index++;
            continue;
        }

        const heading = line.match(/^(#{1,4})\s+(.*)$/);
        if (heading) {
            const level = heading[1].length;
            const text = heading[2].trim();
            const id = slug(text);
            headings.push({ level, text, id });
            out.push(`<h${level} id="${id}">${inline(text)}<a class="anchor" href="#${id}" aria-label="link to this section">#</a></h${level}>`);
            index++;
            continue;
        }

        if (/\|/.test(line) && index + 1 < lines.length && /^\s*\|?[\s:-]+\|[\s:|-]*$/.test(lines[index + 1])) {
            const header = splitRow(line);
            index += 2;
            const rows = [];
            while (index < lines.length && /\|/.test(lines[index]) && lines[index].trim() !== '') {
                rows.push(splitRow(lines[index]));
                index++;
            }
            let table = '<div class="table-wrap"><table><thead><tr>';
            for (const cell of header) table += `<th>${inline(cell)}</th>`;
            table += '</tr></thead><tbody>';
            for (const row of rows) {
                table += '<tr>';
                for (let c = 0; c < header.length; c++) {
                    table += `<td>${inline(row[c] === undefined ? '' : row[c])}</td>`;
                }
                table += '</tr>';
            }
            table += '</tbody></table></div>';
            out.push(table);
            continue;
        }

        if (/^>\s?/.test(line)) {
            const body = [];
            while (index < lines.length && /^>\s?/.test(lines[index])) {
                body.push(lines[index].replace(/^>\s?/, ''));
                index++;
            }
            out.push(`<blockquote>${render(body.join('\n')).html}</blockquote>`);
            continue;
        }

        if (/^(\s*)([-*])\s+/.test(line) || /^(\s*)\d+\.\s+/.test(line)) {
            const parsed = renderList(lines, index);
            out.push(parsed.html);
            index = parsed.next;
            continue;
        }

        if (line.trim() === '') {
            index++;
            continue;
        }

        const body = [];
        while (index < lines.length
            && lines[index].trim() !== ''
            && !/^```/.test(lines[index])
            && !/^(#{1,4})\s+/.test(lines[index])
            && !/^\s*---+\s*$/.test(lines[index])
            && !/^\s*([-*]|\d+\.)\s+/.test(lines[index])
            && !/^>\s?/.test(lines[index])) {
            body.push(lines[index]);
            index++;
        }
        out.push(`<p>${inline(body.join(' ').trim())}</p>`);
    }

    return { html: out.join('\n'), headings };
}

const markdown = fs.readFileSync(SOURCE, 'utf8');
const document = render(markdown);

// The reference's own "Contents" section is list of anchors the sidebar already
// provides; two navigation surfaces on one page is worse than one.
let html = document.html;
const contentsStart = html.indexOf(`<h2 id="${CONTENTS_HEADING}">`);
if (contentsStart >= 0) {
    const nextH2 = html.indexOf('<h2 id="', contentsStart + 10);
    if (nextH2 > 0) {
        html = html.slice(0, contentsStart) + html.slice(nextH2);
    }
}

const navigation = document.headings
    .filter((h) => h.level === 2 && h.id !== CONTENTS_HEADING)
    .map((h) => `<a class="nav-link" href="#${h.id}">${escapeHTML(h.text)}</a>`)
    .join('\n');

const styles = fs.readFileSync(path.join(here, 'styles.css'), 'utf8');
const landing = fs.readFileSync(path.join(here, 'index.template.html'), 'utf8');

const apiPage = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>API reference — exteraGram plugin runtime for iOS</title>
<meta name="description" content="The complete plugin API surface of the exteraGram-compatible JavaScriptCore runtime in the Telegram iOS sideload build.">
<link rel="stylesheet" href="styles.css">
</head>
<body class="doc-page">
<header class="topbar">
<a class="brand" href="index.html">extera<span>iOS</span></a>
<nav class="topnav">
<a href="index.html">Overview</a>
<a href="api.html" class="active">API reference</a>
<a href="https://github.com/DarkLuny/tg-ipa">GitHub</a>
</nav>
</header>
<div class="layout">
<aside class="sidebar">
<div class="sidebar-title">Contents</div>
${navigation}
</aside>
<main class="content">
<article>
${html}
</article>
<footer class="doc-footer">
<p>Generated from <code>submodules/ExteraPluginKit/docs/API.md</code>. If this page and the source disagree, the source is right.</p>
</footer>
</main>
</div>
<script>
document.querySelectorAll('.code-block').forEach(function (wrap) {
    var pre = wrap.querySelector('pre');
    if (!pre) { return; }
    var button = document.createElement('button');
    button.className = 'copy';
    button.textContent = 'copy';
    button.addEventListener('click', function () {
        var code = pre.querySelector('code');
        var text = code ? code.textContent : pre.textContent;
        if (navigator.clipboard) { navigator.clipboard.writeText(text); }
        button.textContent = 'copied';
        setTimeout(function () { button.textContent = 'copy'; }, 1200);
    });
    wrap.appendChild(button);
});
var links = Array.prototype.slice.call(document.querySelectorAll('.nav-link'));
function markActive() {
    var best = null;
    var y = window.scrollY + 120;
    links.forEach(function (link) {
        var target = document.querySelector(link.getAttribute('href'));
        if (target && target.offsetTop <= y) { best = link; }
    });
    links.forEach(function (link) { link.classList.toggle('current', link === best); });
}
window.addEventListener('scroll', markActive, { passive: true });
markActive();
</script>
</body>
</html>`;

fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(path.join(OUT, 'styles.css'), styles, 'utf8');
fs.writeFileSync(path.join(OUT, 'api.html'), apiPage, 'utf8');
fs.writeFileSync(path.join(OUT, 'index.html'), landing, 'utf8');
fs.writeFileSync(path.join(OUT, 'api.md'), markdown, 'utf8');
// Pages runs Jekyll unless told not to, and Jekyll would silently drop files
// whose names it does not expect.
fs.writeFileSync(path.join(OUT, '.nojekyll'), '', 'utf8');

console.log('sections: ' + navigation.split('\n').length);
console.log('output: ' + OUT);

// A render gap shows up as a nav link with no heading behind it. Fail the build
// rather than publishing a page whose sidebar points at nothing.
const rendered = fs.readFileSync(path.join(OUT, 'api.html'), 'utf8');
const anchors = [...rendered.matchAll(/class="nav-link" href="#([^"]+)"/g)].map((m) => m[1]);
const unresolved = anchors.filter((id) => !rendered.includes(`id="${id}"`));
if (anchors.length === 0) {
    console.error('no sections rendered');
    process.exit(1);
}
if (unresolved.length > 0) {
    console.error('unresolved anchors: ' + unresolved.join(', '));
    process.exit(1);
}
console.log('anchors: ' + anchors.length + ', all resolve');