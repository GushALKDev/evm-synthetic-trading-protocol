// Neutral glyphs rather than the assets' logos: the pairs are synthetic, priced from Chainlink testnet feeds.
export function PairIcon({ symbol }: { symbol: string }) {
  return (
    <svg className="token-icon" viewBox="0 0 22 22" aria-hidden="true">
      <circle cx="11" cy="11" r="11" fill="var(--sunken)" stroke="var(--rule-strong)" />
      <text x="11" y="15" textAnchor="middle" fontSize="10.5" fontWeight="600" fill="var(--ink-2)" fontFamily="IBM Plex Sans, sans-serif">
        {symbol.slice(0, 1)}
      </text>
    </svg>
  )
}

/** Side of a position: the word and an arrow carry the meaning, the color only repeats it */
export function SideTag({ isLong, leverage }: { isLong: boolean; leverage?: bigint }) {
  return (
    <span className="side-tag" data-side={isLong ? 'long' : 'short'}>
      <svg width="10" height="10" viewBox="0 0 10 10" aria-hidden="true">
        {isLong ? <path d="M5 1.5l3.5 5h-7z" fill="currentColor" /> : <path d="M5 8.5l3.5-5h-7z" fill="currentColor" />}
      </svg>
      {isLong ? 'Long' : 'Short'}
      {leverage !== undefined ? ` ${leverage}x` : null}
    </span>
  )
}

export function Mark() {
  return (
    <svg width="26" height="26" viewBox="0 0 32 32" aria-hidden="true">
      <rect width="32" height="32" rx="8" fill="var(--ink)" />
      <rect x="6" y="9" width="8" height="5" rx="1.5" fill="var(--mark-held)" />
      <rect x="15" y="9" width="11" height="5" rx="1.5" fill="var(--mark-held)" />
      <rect x="6" y="18" width="15" height="5" rx="1.5" fill="var(--mark-owed)" />
      <rect x="22" y="18" width="4" height="5" rx="1.5" fill="var(--mark-accent)" />
    </svg>
  )
}

export function ToastIcon({ tone }: { tone: 'pending' | 'success' | 'error' }) {
  if (tone === 'pending')
    return (
      <svg className="toast-icon" viewBox="0 0 18 18" aria-hidden="true">
        <circle cx="9" cy="9" r="7" fill="none" stroke="currentColor" strokeWidth="2" strokeDasharray="30 14" />
      </svg>
    )
  if (tone === 'success')
    return (
      <svg className="toast-icon" viewBox="0 0 18 18" aria-hidden="true">
        <circle cx="9" cy="9" r="8" fill="currentColor" />
        <path d="M5.5 9.2l2.3 2.3 4.7-4.9" fill="none" stroke="var(--surface)" strokeWidth="1.8" strokeLinecap="round" />
      </svg>
    )
  return (
    <svg className="toast-icon" viewBox="0 0 18 18" aria-hidden="true">
      <circle cx="9" cy="9" r="8" fill="currentColor" />
      <path d="M9 5v5M9 12.6v.1" stroke="var(--surface)" strokeWidth="1.9" strokeLinecap="round" />
    </svg>
  )
}

export function CloseIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true">
      <path d="M4 4l8 8M12 4l-8 8" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
    </svg>
  )
}
