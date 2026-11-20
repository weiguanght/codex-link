// Both engines produce token trees. Return UTF-16 ranges for UIKit, with
// inner scopes overriding outer scopes and no HTML conversion.
const scopes = {
    'built_in': 'function', 'class-name': 'type', 'meta': 'attribute',
    'literal': 'constant', 'atom': 'constant', 'symbol': 'constant',
    'regexp': 'string', 'subst': 'property', 'section': 'function',
    'name': 'function', 'title': 'function', 'macro': 'attribute',
    'variable': 'property'
};

globalThis.codexLinkSyntaxRanges = function (code, language) {
    const ranges = [];
    let offset = 0;

    function append(text, scope) {
        if (!code.startsWith(text, offset)) throw new Error('Syntax tokens differ from source');
        if (scope && text.length) {
            const style = scopes[scope] || scope;
            const previous = ranges[ranges.length - 1];
            if (previous && previous[2] === style && previous[0] + previous[1] === offset) {
                previous[1] += text.length;
            } else {
                ranges.push([offset, text.length, style]);
            }
        }
        offset += text.length;
    }

    if (language === 'agda') {
        function walk(node, scope) {
            if (typeof node === 'string') append(node, scope);
            else if (Array.isArray(node)) node.forEach(child => walk(child, scope));
            else walk(node.content, node.type);
        }
        walk(Prism.tokenize(code, Prism.languages.agda), null);
    } else {
        const result = hljs.highlight(code, { language, ignoreIllegals: true });
        if (result.errorRaised) return [];
        result._emitter.walk({
            stack: [],
            addText(text) { append(text, this.stack[this.stack.length - 1]); },
            openNode(node) { this.stack.push(node.scope || this.stack[this.stack.length - 1]); },
            closeNode() { this.stack.pop(); }
        });
    }
    return offset === code.length ? ranges : [];
};
