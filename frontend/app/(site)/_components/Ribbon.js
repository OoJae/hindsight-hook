"use client";
import { useEffect, useMemo, useRef, useState } from "react";
import { Canvas, useFrame, useThree } from "@react-three/fiber";
import * as THREE from "three";

/* ---------------------------------------------------------------------------
   The Tick Ribbon.

   Its shape is not invented: it is 800 consecutive real ETH/USDC swaps from
   Unichain mainnet (public/ribbon.bin, exported by backtest/export_ribbon.py).
   Displacement is the pool's tick. The bracket is the settlement window, and
   the only part of the ribbon that lights up is the segment currently inside
   it — signal for a refund, vermilion for a forfeit. Everything else stays
   dim, so the accent colours stay events rather than decoration.
   ------------------------------------------------------------------------ */

const LEN = 58;      // world units along the tape
const HEIGHT = 9;    // world units of tick displacement
const HALF_W = 4.6;  // ribbon half-width in Z — it must read as a surface

const vert = /* glsl */ `
  attribute float aT;        // 0..1 along the tape
  attribute float aToxic;    // 1 if this swap forfeited
  varying float vT;
  varying float vToxic;
  varying float vEdge;
  void main() {
    vT = aT;
    vToxic = aToxic;
    vEdge = abs(position.z) / ${HALF_W.toFixed(2)};
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`;

const frag = /* glsl */ `
  precision mediump float;
  uniform float uBracket;    // window centre, 0..1
  uniform float uWidth;      // window half-width, in t
  uniform float uOpen;       // 0 = closed/settled, 1 = still open
  uniform float uPresence;   // the tape yields to the headline until you scroll
  uniform vec3 uDim;
  uniform vec3 uSignal;
  uniform vec3 uClaw;
  varying float vT;
  varying float vToxic;
  varying float vEdge;
  void main() {
    float inWin = 1.0 - smoothstep(uWidth * 0.75, uWidth, abs(vT - uBracket));
    // While the window is open the verdict is unknown: it reads as neutral
    // signal. Only once it closes does a forfeit declare itself.
    vec3 settled = mix(uSignal, uClaw, vToxic * (1.0 - uOpen));
    vec3 col = mix(uDim, settled, inWin);
    // The ribbon is brighter at its spine than at its edges, so it reads as a
    // surface catching light rather than a flat sticker.
    float body = mix(1.0, 0.45, vEdge);
    float a = mix(0.72, 1.0, inWin) * uPresence;
    gl_FragColor = vec4(col * body * mix(0.55, 1.0, uPresence), a);
  }
`;

function Tape({ pts, toxic, progressRef }) {
  const { camera, size } = useThree();

  // The layout concept is a mono gutter on the left and the instrument on the
  // right. setViewOffset composes the 3D to match, instead of letting the tape
  // sit under the headline. Disabled on narrow screens, where the copy is
  // full-width and the tape is pure atmosphere behind it.
  useEffect(() => {
    const wide = size.width > 900;
    if (wide) {
      camera.setViewOffset(size.width, size.height, -size.width * 0.26, 0, size.width, size.height);
    } else {
      camera.clearViewOffset();
    }
    camera.updateProjectionMatrix();
    return () => { camera.clearViewOffset(); camera.updateProjectionMatrix(); };
  }, [camera, size.width, size.height]);

  const geometry = useMemo(() => {
    const n = pts.length;
    const pos = new Float32Array(n * 2 * 3);
    const aT = new Float32Array(n * 2);
    const aToxic = new Float32Array(n * 2);
    for (let i = 0; i < n; i++) {
      const { x, y, t } = pts[i];
      for (const s of [0, 1]) {
        const o = (i * 2 + s) * 3;
        pos[o] = x;
        pos[o + 1] = y;
        pos[o + 2] = s === 0 ? -HALF_W : HALF_W;
        aT[i * 2 + s] = t;
        aToxic[i * 2 + s] = toxic[i];
      }
    }
    const idx = [];
    for (let i = 0; i < n - 1; i++) {
      const a = i * 2;
      idx.push(a, a + 1, a + 2, a + 1, a + 3, a + 2);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute("position", new THREE.BufferAttribute(pos, 3));
    g.setAttribute("aT", new THREE.BufferAttribute(aT, 1));
    g.setAttribute("aToxic", new THREE.BufferAttribute(aToxic, 1));
    g.setIndex(idx);
    return g;
  }, [pts, toxic]);

  const material = useMemo(
    () =>
      new THREE.ShaderMaterial({
        vertexShader: vert,
        fragmentShader: frag,
        transparent: true,
        side: THREE.DoubleSide,
        depthWrite: false,
        uniforms: {
          uBracket: { value: 0.08 },
          uWidth: { value: 0.045 },
          uOpen: { value: 1 },
          uPresence: { value: 0.34 },
          uDim: { value: new THREE.Color("#5a6b45") },
          uSignal: { value: new THREE.Color("#ccff00") },
          uClaw: { value: new THREE.Color("#ff5a36") },
        },
      }),
    []
  );

  useFrame(() => {
    const p = progressRef.current;

    // Act 0 holds the bracket just ahead of the trade; the window then travels
    // and closes across acts 1-3. One motion, not four.
    const travel = Math.min(1, Math.max(0, (p - 0.06) / 0.62));
    const bracket = 0.1 + travel * 0.72;
    const open = 1 - Math.min(1, Math.max(0, (p - 0.42) / 0.16));

    // The hero belongs to the headline. The instrument arrives as you scroll.
    const ceiling = size.width > 900 ? 1 : 0.5;
    material.uniforms.uPresence.value =
      (0.34 + 0.66 * Math.min(1, Math.max(0, (p - 0.02) / 0.13))) * ceiling;
    material.uniforms.uBracket.value = bracket;
    material.uniforms.uOpen.value = open;
    material.uniforms.uWidth.value = 0.045 + (1 - open) * 0.012;

    // The camera rides the tape, easing back at the end so the whole run is in
    // frame for the closing statistic.
    const pullBack = Math.min(1, Math.max(0, (p - 0.72) / 0.28));
    camera.position.x = bracket * LEN - 15 + pullBack * 2;
    camera.position.y = 8.5 + pullBack * 10;
    camera.position.z = 8.5 + pullBack * 16;
    camera.lookAt(bracket * LEN + 13, -1.5 - pullBack * 2, -1);
  });

  return <mesh geometry={geometry} material={material} frustumCulled={false} />;
}

/** The settlement window, as a physical caliper riding above the tape. */
function Bracket({ pts, progressRef }) {
  const g = useRef();
  const yAt = useMemo(() => {
    return (t) => {
      const i = Math.min(pts.length - 1, Math.max(0, Math.round(t * (pts.length - 1))));
      return pts[i].y;
    };
  }, [pts]);

  useFrame(() => {
    if (!g.current) return;
    const p = progressRef.current;
    const travel = Math.min(1, Math.max(0, (p - 0.06) / 0.62));
    const bracket = 0.1 + travel * 0.72;
    const close = Math.min(1, Math.max(0, (p - 0.42) / 0.16));
    const presence = Math.min(1, Math.max(0, (p - 0.02) / 0.13));
    g.current.position.x = bracket * LEN;
    g.current.position.y = yAt(bracket) + 3.4;
    // The legs descend as the window closes over the segment.
    g.current.scale.y = 0.35 + close * 0.65;
    g.current.traverse((o) => {
      if (o.material) o.material.opacity = 0.8 * presence;
    });
  });

  return (
    <group ref={g}>
      {/* A gate the tape passes through. Spanning the road's width rather than
          its length is the only way this reads from a camera pointed down the
          road — as a span in X it foreshortens into a skewed staple. */}
      <mesh position={[0, 2.4, 0]}>
        <boxGeometry args={[0.1, 0.1, (HALF_W + 0.9) * 2]} />
        <meshBasicMaterial color="#edeae4" transparent opacity={0} />
      </mesh>
      {[-(HALF_W + 0.9), HALF_W + 0.9].map((z) => (
        <mesh key={z} position={[0, 0.9, z]}>
          <boxGeometry args={[0.1, 3.1, 0.1]} />
          <meshBasicMaterial color="#edeae4" transparent opacity={0} />
        </mesh>
      ))}
    </group>
  );
}

/** θ, drawn where it actually is: a level the markout either clears or doesn't. */
function ThetaPlane({ progressRef }) {
  const m = useRef();
  useFrame(() => {
    if (!m.current) return;
    const p = progressRef.current;
    const show = Math.min(1, Math.max(0, (p - 0.3) / 0.14));
    m.current.material.opacity = show * 0.07;
  });
  return (
    <mesh ref={m} rotation={[-Math.PI / 2, 0, 0]} position={[LEN / 2, 0.9, 0]}>
      <planeGeometry args={[LEN * 1.4, 26]} />
      <meshBasicMaterial color="#ccff00" transparent opacity={0} depthWrite={false} />
    </mesh>
  );
}

function Scene({ pts, toxic, progressRef }) {
  return (
    <>
      <color attach="background" args={["#0b0d0e"]} />
      <fog attach="fog" args={["#0b0d0e", 30, 105]} />
      <Tape pts={pts} toxic={toxic} progressRef={progressRef} />
      <Bracket pts={pts} progressRef={progressRef} />
      <ThetaPlane progressRef={progressRef} />
    </>
  );
}

export default function Ribbon({ progressRef }) {
  const [data, setData] = useState(null);

  useEffect(() => {
    // basePath is NOT applied to fetch() by Next — same precedent as the
    // explorer page. Getting this wrong 404s only in production.
    const base = process.env.NEXT_PUBLIC_BASE_PATH ?? "";
    let alive = true;
    (async () => {
      try {
        const meta = await (await fetch(`${base}/ribbon-meta.json`)).json();
        const buf = await (await fetch(`${base}/${meta.bin}`)).arrayBuffer();
        const f = new Float32Array(buf);
        const n = meta.n;
        const S = meta.stride;
        let tickLo = Infinity, tickHi = -Infinity, tMax = 0;
        for (let i = 0; i < n; i++) {
          tickLo = Math.min(tickLo, f[i * S + 1]);
          tickHi = Math.max(tickHi, f[i * S + 1]);
          tMax = Math.max(tMax, f[i * S]);
        }
        const mid = (tickLo + tickHi) / 2;
        const span = Math.max(1, tickHi - tickLo);
        const pts = [];
        const toxic = new Float32Array(n);
        for (let i = 0; i < n; i++) {
          const t = f[i * S] / tMax;
          pts.push({
            t,
            x: t * LEN,
            y: ((f[i * S + 1] - mid) / span) * HEIGHT,
          });
          toxic[i] = f[i * S + 2] > f[i * S + 3] ? 1 : 0; // markout > theta
        }
        if (alive) setData({ pts, toxic });
      } catch {
        /* the page is fully legible without the canvas */
      }
    })();
    return () => { alive = false; };
  }, []);

  if (!data) return null;

  return (
    <Canvas
      dpr={[1, 1.75]}
      gl={{ antialias: true, powerPreference: "high-performance" }}
      camera={{ fov: 42, position: [0, 2.4, 13], near: 0.1, far: 120 }}
    >
      <Scene pts={data.pts} toxic={data.toxic} progressRef={progressRef} />
    </Canvas>
  );
}
