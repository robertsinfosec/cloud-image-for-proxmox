# GitHub Copilot Instructions

This file provides coding standards and guidelines for GitHub Copilot when assisting with this project.

## Project Philosophy

### Code Quality Standards

**We only accept production-ready, professional code.**

This project is used in real production environments managing real infrastructure. Every line of code must meet professional standards:

- ✅ **Production-ready from day one** - No placeholders, TODOs, or "good enough for now"
- ✅ **Best practices always** - Follow language idioms, security guidelines, and proven patterns
- ✅ **Zero tolerance for technical debt** - We aggressively refactor and improve code quality
- ✅ **Defensive programming** - Validate inputs, handle errors, anticipate edge cases
- ✅ **Maintainable and readable** - Code should be self-documenting with clear intent

**Key Principles:**
1. **Idempotent operations** - Scripts can be run multiple times safely
2. **Fail fast and loud** - Catch errors early, provide clear messages
3. **Test edge cases** - Empty disks, network failures, small storage, etc.
4. **No silent failures** - Every operation is validated
5. **Backwards compatibility** - Changes shouldn't break existing deployments

### Documentation Philosophy

**Act as a seasoned mentor who genuinely wants to help users understand.**

Documentation is not an afterthought - it's how we lower the barrier to entry and empower users to succeed.

**Documentation Standards:**
- ✅ **Write at 8th grade reading level** - Clear, simple language
- ✅ **Be generous with explanations** - Don't write the minimum, write what's helpful
- ✅ **Use GitHub-flavored Markdown admonitions** - Tips, notes, warnings, cautions
- ✅ **Show, don't just tell** - Include examples for every major feature
- ✅ **Explain the "why"** - Help users understand concepts, not just commands
- ✅ **Anticipate questions** - What would a new user wonder about?

**Admonition Usage:**
```markdown
> [!NOTE]
> Background information that helps understand the concept

> [!TIP]
> Helpful suggestions and best practices

> [!IMPORTANT]
> Critical information that affects decisions

> [!CAUTION]
> Warnings about potentially destructive operations

> [!WARNING]
> Serious warnings about data loss or security
```

**Examples of Good vs Bad Documentation:**

**Bad (minimal, assumes knowledge):**
```markdown
Use `--type lvm-thin` for VMs.
```

**Good (helpful, educational):**
```markdown
### LVM-Thin for Virtual Machines

Use `--type lvm-thin` when provisioning storage for VMs:

```bash
./proxmox-storage.sh --provision --type lvm-thin --force
```

> [!TIP]
> LVM-Thin is Proxmox's recommended storage type for VMs. It gives you:
> - **Snapshots** - Take backups without stopping VMs
> - **Thin provisioning** - Allocate 100GB but only use space as needed
> - **Fast clones** - Duplicate VMs in seconds
>
> This is what Proxmox uses by default with `local-lvm`, but this script creates a separate thin pool per disk for better organization.

**When to use something else:**
- Use `--type dir` for simple file storage (ISO files, backups)
- Use `--type nfs` for shared storage across cluster nodes
```

## Character Encoding Standards

### ❌ NEVER Use These Characters

**Smart Quotes** - These cause string matching issues in tools:
- ❌ `"` (U+201C - left double quotation mark)
- ❌ `"` (U+201D - right double quotation mark)
- ❌ `'` (U+2018 - left single quotation mark)
- ❌ `'` (U+2019 - right single quotation mark)
- ✅ Use straight quotes: `"` and `'`

**Special Arrows** - These break search/replace operations:
- ❌ `→` (U+2192 - rightwards arrow)
- ❌ `←` (U+2190 - leftwards arrow)
- ❌ `↑` (U+2191 - upwards arrow)
- ❌ `↓` (U+2193 - downwards arrow)
- ✅ Use ASCII alternatives: `->`, `<-`, or just write "to"

**Special Dashes** - Can cause matching issues:
- ❌ `—` (U+2014 - em dash)
- ❌ `–` (U+2013 - en dash)
- ✅ Use ASCII: `-` (hyphen) or `--` (double hyphen)

### Why This Matters

This codebase uses tools like `sed`, `grep`, `awk`, and `replace_string_in_file` that require exact byte-for-byte matches. Unicode special characters:
1. **Break text replacement tools** - `replace_string_in_file` cannot match strings with special characters
2. **Cause terminal issues** - May display incorrectly in different locales
3. **Create maintenance burden** - Harder to search and modify files programmatically
4. **Are invisible to users** - Look identical to ASCII but behave differently

### Examples

**Bad:**
```markdown
`<N>` is taken from the node hostname (e.g., `pve1` → `1`)
"This is a quote" and it's using smart quotes
```

**Good:**
```markdown
`<N>` is taken from the node hostname (e.g., `pve1` -> `1`)
"This is a quote" and it's using straight quotes
```

## Code Style Guidelines

### Bash Scripts

1. **Use strict error handling:**
   ```bash
   set -Eeuo pipefail
   ```

2. **Quote all variables:**
   ```bash
   # Good
   if [[ -n "$variable" ]]; then
   
   # Bad
   if [[ -n $variable ]]; then
   ```

3. **Use `[[` for conditionals** instead of `[`:
   ```bash
   # Good
   if [[ "$var" == "value" ]]; then
   
   # Bad
   if [ "$var" == "value" ]; then
   ```

4. **Prefer `$(command)` over backticks:**
   ```bash
   # Good
   result="$(command)"
   
   # Bad
   result=`command`
   ```

5. **Always handle errors explicitly:**
   ```bash
   if ! run_cmd "Description" command args; then
     p_err "Failed: description"
     return 1
   fi
   ```

### Documentation (Markdown)

1. **Use consistent heading levels** - Don't skip levels
2. **Include examples** for all major features
3. **Use code blocks with language specifiers:**
   ````markdown
   ```bash
   ./script.sh --option
   ```
   ````

4. **Use notes/tips/warnings appropriately:**
   ```markdown
   > [!NOTE]
   > Informational content
   
   > [!TIP]
   > Helpful suggestion
   
   > [!CAUTION]
   > Warning about destructive operation
   ```

5. **Link to related sections** using relative paths:
   ```markdown
   See [Storage Documentation](src/proxmox-storage.md) for details.
   ```

## Project-Specific Conventions

### Storage Naming

- `HDD-#A` format for rotational disks (where # is node digit)
- `SSD-#A` format for solid-state disks
- `NFS-#A` format for network storage
- Backend type (dir/lvm/lvmthin) is NOT in the name

### Error Messages

Always provide actionable guidance:
```bash
# Good
die "--type nfs requires --nfs-server\n       Example: --type nfs --nfs-server 192.168.1.100 --nfs-path /export/storage"

# Bad
die "--nfs-server required"
```

### Function Naming

- Use snake_case: `provision_disk_dir`, `ensure_mount`
- Action verbs first: `get_system_disk`, `validate_device`
- Boolean checks start with `is_`: `is_proxmox`, `is_shared_flag`

### Comments

1. **Explain WHY, not WHAT:**
   ```bash
   # Good: Use 95% to leave space for metadata overhead
   thin_size_kb=$(awk "BEGIN {printf \"%.0f\", $vg_size_kb * 0.95}")
   
   # Bad: Calculate 95% of VG size
   thin_size_kb=$(awk "BEGIN {printf \"%.0f\", $vg_size_kb * 0.95}")
   ```

2. **Document non-obvious behavior:**
   ```bash
   # NFS storage is node-local in config but data is shared
   ```

3. **Mark TODOs clearly:**
   ```bash
   # TODO: Add support for iSCSI storage type
   ```

## Testing Approach

When suggesting changes:
1. Consider edge cases (empty disks, small disks, network failures)
2. Ensure idempotency (can run multiple times safely)
3. Validate all inputs before destructive operations
4. Provide `--whatif` simulation mode support
5. Test both successful and failure paths

## Common Pitfalls to Avoid

1. **Don't assume tools are installed** - Check with `command -v` first
2. **Don't hardcode paths** - Use variables and detect dynamically
3. **Don't skip error checking** - Every important operation should be validated
4. **Don't use single `=`** in bash conditionals - Use `==` or `=~`
5. **Don't forget to handle special characters in user input** - Quote and validate

---

**Remember:** This project prioritizes reliability, safety, and maintainability over cleverness. When in doubt, be explicit and verbose rather than terse and clever.
