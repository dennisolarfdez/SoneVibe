```markdown
SoneVibe fork notes
- Purpose: Fork of Compound v2 with SoneVibe branding, compile with Solidity ^0.8.30 and optimizer runs=200.
- Branch: sonevibe/v2-branding
- Files added now:
  - hardhat.config.js (Solidity 0.8.30, optimizer runs=200)
  - .github/workflows/ci.yml (CI for compile + tests)
  - NOTES.md (este archivo)
- Next safe steps (no terminal required):
  1) Revisar CI run en Actions (tras push) para ver que compila.
  2) Aplicar los cambios de pragma en contratos por lotes (te doy 10 archivos por mensaje para no romper nada).
  3) Añadir cambios de branding en README y docs si quieres.
- IMPORTANT: No subir claves privadas. Para deploy usa .env en tu máquina local.
