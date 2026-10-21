// Prints the WCAG contrast of the app's data colors against the ground, surface and sunken greys, in both themes,
// read from src/styles.css. The figures in DESIGN.md come from this script: node scripts/contrast.mjs
import { readFileSync } from 'node:fs'

const css = readFileSync(new URL('../src/styles.css', import.meta.url), 'utf8')
const block = (start) => css.slice(css.indexOf(start), css.indexOf('}', css.indexOf(start)))
const tokens = (text) => Object.fromEntries([...text.matchAll(/--([\w-]+):\s*(#[0-9a-f]{6})/gi)].map((m) => [m[1], m[2]]))
const light = tokens(block(':root {'))
const dark = { ...light, ...tokens(block('@media (prefers-color-scheme: dark)')) }

const luminance = (hex) => {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4))
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}
const ratio = (a, b) => {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x)
  return ((hi + 0.05) / (lo + 0.05)).toFixed(2)
}

const roles = ['accent', 'long', 'short', 'seg-held', 'seg-lp', 'danger', 'warn']
console.log('token     | light   | ground surface sunken | dark    | ground surface sunken')
for (const role of roles) {
  const l = light[role]
  const d = dark[role]
  const row = (c, t) => [t.ground, t.surface, t.sunken].map((bg) => ratio(c, bg).padStart(6)).join(' ')
  console.log(`${role.padEnd(9)} | ${l} | ${row(l, light)} | ${d} | ${row(d, dark)}`)
}
