import { useSyncExternalStore } from 'react'

export type Page = 'trade' | 'vault' | 'positions' | 'how'

export const pages: { page: Page; path: string; label: string }[] = [
  { page: 'trade', path: '/', label: 'Trade' },
  { page: 'vault', path: '/vault', label: 'Vault' },
  { page: 'positions', path: '/positions', label: 'All positions' },
  { page: 'how', path: '/how-it-works', label: 'How it works' },
]

function subscribe(onChange: () => void) {
  window.addEventListener('popstate', onChange)
  return () => window.removeEventListener('popstate', onChange)
}

const currentUrl = () => window.location.pathname + window.location.hash

/** Scrolls to the element the URL fragment names, or to the top when there is none. */
export function scrollToTarget() {
  const target = window.location.hash ? document.getElementById(window.location.hash.slice(1)) : null
  if (target) target.scrollIntoView()
  else window.scrollTo(0, 0)
}

export function navigate(href: string) {
  // The same URL re-renders nothing, so the scroll cannot wait for an effect.
  if (href === currentUrl()) return scrollToTarget()
  window.history.pushState(null, '', href)
  window.dispatchEvent(new PopStateEvent('popstate'))
}

/** The page for the current path. Unknown paths show the trade page: the host serves index.html for every path. */
export function useRoute(): { page: Page; url: string } {
  const url = useSyncExternalStore(subscribe, currentUrl)
  const path = url.split('#')[0].replace(/\/+$/, '') || '/'
  return { page: pages.find((p) => p.path === path)?.page ?? 'trade', url }
}
