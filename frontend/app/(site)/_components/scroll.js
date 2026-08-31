// One scroll signal for the whole site. Motion (mounted once in the site
// layout) writes it; the Ribbon reads it every frame. A module ref rather than
// context, because this changes on every frame and must never re-render React.
export const scrollProgress = { current: 0 };
