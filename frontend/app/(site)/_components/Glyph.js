export default function Glyph({ size = 24, ...rest }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none" aria-hidden="true" {...rest}>
      <path d="M12 6 H27" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" opacity=".6" />
      <path d="M12 6 V10" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" opacity=".6" />
      <path d="M27 6 V10" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" opacity=".6" />
      <path d="M2 25 H12 L21 14 H30" stroke="currentColor" strokeWidth="2.6" strokeLinecap="round" strokeLinejoin="round" />
      <circle cx="12" cy="25" r="2.8" fill="currentColor" />
    </svg>
  );
}
