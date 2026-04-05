---
name: coding-quality
description: Apply when writing, modifying, or reviewing code. Combines behavioral guidelines to reduce common LLM coding mistakes (think before coding, simplicity first, surgical changes) with modern web development best practices (security, CSP, browser compatibility, Lighthouse audits). Triggers on implementation tasks, code changes, refactoring, bug fixes, feature development, "apply best practices", "code quality review", "modernize code", or "audit code".
---

# Coding Quality

Behavioral guidelines + web audit checklist to produce clean, secure, maintainable code.

---

## Part 1: Coding Principles (Behavioral)

Guidelines to reduce common LLM coding mistakes. Bias toward caution over speed — for trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

- State assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.
- Disagree honestly. If the user's approach seems wrong, say so — don't be sycophantic.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:

- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it — don't delete it.

When your changes create orphans:

- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

**The test:** Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:

- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

---

## Part 2: Web Best Practices (Audit Checklist)

Modern web development standards based on Lighthouse best practices audits.

### Security

**HTTPS everywhere:**
- Enforce HTTPS, no mixed content
- HSTS: `Strict-Transport-Security: max-age=31536000; includeSubDomains; preload`

**CSP headers:**
```
Content-Security-Policy:
  default-src 'self';
  script-src 'self' 'nonce-abc123' https://trusted.com;
  style-src 'self' 'nonce-abc123';
  img-src 'self' data: https:;
  connect-src 'self' https://api.example.com;
  frame-ancestors 'self';
  base-uri 'self';
  form-action 'self';
```

**Security headers:**
```
X-Frame-Options: DENY
X-Content-Type-Options: nosniff
Referrer-Policy: strict-origin-when-cross-origin
Permissions-Policy: geolocation=(), microphone=(), camera=()
```

**Input sanitization:**
```javascript
// ❌ XSS vulnerable
element.innerHTML = userInput

// ✅ Safe
element.textContent = userInput

// ✅ If HTML needed
import DOMPurify from 'dompurify'
element.innerHTML = DOMPurify.sanitize(userInput)
```

**No vulnerable libraries:** Run `npm audit` regularly.

### Browser Compatibility

- HTML5 doctype: `<!DOCTYPE html>`
- Charset first in head: `<meta charset="UTF-8" />`
- Viewport: `<meta name="viewport" content="width=device-width, initial-scale=1" />`
- Feature detection over browser detection
- Passive event listeners for scroll/touch

### Code Quality Patterns

**Avoid blocking patterns:**
```html
<!-- ❌ --> <script src="heavy.js"></script>
<!-- ✅ --> <script defer src="heavy.js"></script>
```

**Event delegation:**
```javascript
// ❌ Handler per element
items.forEach(item => item.addEventListener('click', handleClick))

// ✅ Single delegated handler
container.addEventListener('click', e => {
  if (e.target.matches('.item')) handleClick(e)
})
```

**Memory cleanup:**
```javascript
const controller = new AbortController()
window.addEventListener('resize', handler, { signal: controller.signal })
// Cleanup: controller.abort()
```

**Error handling:**
```javascript
try {
  riskyOperation()
} catch (error) {
  errorTracker.captureException(error)
  showErrorMessage('Something went wrong.')
}
```

**Source maps:** Use `hidden-source-map` in production, never expose source code.

### Audit Checklist

#### Security (critical)
- [ ] HTTPS enabled, no mixed content
- [ ] No vulnerable dependencies (`npm audit`)
- [ ] CSP headers configured
- [ ] Security headers present
- [ ] No exposed source maps

#### Compatibility
- [ ] Valid HTML5 doctype
- [ ] Charset declared first in head
- [ ] Viewport meta tag present
- [ ] No deprecated APIs used
- [ ] Passive event listeners for scroll/touch

#### Code Quality
- [ ] No console errors
- [ ] Valid HTML (no duplicate IDs)
- [ ] Semantic HTML elements used
- [ ] Proper error handling
- [ ] Memory cleanup in components

#### UX
- [ ] No intrusive interstitials
- [ ] Permission requests in context
- [ ] Clear error messages
- [ ] Appropriate image aspect ratios

### Tools

| Tool | Purpose |
|------|---------|
| `npm audit` | Dependency vulnerabilities |
| Lighthouse | Best practices audit |
| [W3C Validator](https://validator.w3.org) | HTML validation |
| [SecurityHeaders.com](https://securityheaders.com) | Header analysis |
| [Observatory](https://observatory.mozilla.org) | Security scan |
