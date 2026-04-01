// EVM.NOW project constants shared across scripts and deployment modules.

export const logo = [
  '<defs><linearGradient id="lg" x1="27.5" y1="13" x2="-3" y2="13" gradientUnits="userSpaceOnUse">',
  '<stop stop-color="#2B2B2B"/><stop offset="1" stop-color="#646464"/>',
  '</linearGradient></defs>',
  '<path d="M23 26H3V23H0V0H23V26Z" fill="url(#lg)"/>',
  '<path d="M6 8H9V11H6V8Z" fill="#F8F8F8"/>',
  '<path d="M6 11H9V14H6V11Z" fill="#F8F8F8"/>',
  '<path d="M9 11H12V14H9V11Z" fill="#F8F8F8"/>',
  '<path d="M12 11H15V14H12V11Z" fill="#F8F8F8"/>',
  '<path d="M6 14H9V17H6V14Z" fill="#F8F8F8"/>',
  '<path d="M9 17H12V20H9V17Z" fill="#F8F8F8"/>',
  '<path d="M12 17H15V20H12V17Z" fill="#F8F8F8"/>',
  '<path d="M15 17H18V20H15V17Z" fill="#F8F8F8"/>',
  '<path d="M9 5H12V8L9 8V5Z" fill="#F8F8F8"/>',
  '<path d="M12 5H15V8H12V5Z" fill="#F8F8F8"/>',
  '<path d="M6 5H9V8H6V5Z" fill="#F8F8F8"/>',
].join('')

// $10, $69, $250, $1000 (8 decimals)
export const tierPrices = [
  1_000_000_000n,
  6_900_000_000n,
  25_000_000_000n,
  100_000_000_000n,
] as const

export const tierNames = ['supporter', 'gold', 'platinum', 'partner']
