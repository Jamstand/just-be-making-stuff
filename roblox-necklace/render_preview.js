// Renders preview.png with three.js in headless Chromium. Usage: node render_preview.js <path-to-three.min.js>
const fs = require('fs'), path = require('path'), { chromium } = require('playwright');
(async () => {
  const dir = __dirname;
  const obj = fs.readFileSync(path.join(dir, 'BritNecklace.obj'), 'utf8');
  const tex = 'data:image/png;base64,' + fs.readFileSync(path.join(dir, 'BritNecklace_texture.png')).toString('base64');
  const three = fs.readFileSync(process.argv[2], 'utf8');
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader'] });
  const page = await browser.newPage({ viewport: { width: 1000, height: 1000 }, deviceScaleFactor: 2 });
  await page.setContent('<body style="margin:0"></body>');
  await page.addScriptTag({ content: three });
  await page.evaluate(async ({ obj, tex }) => {
    const v = [], t = [], n = [], P = [], U = [], N = [];
    for (const l of obj.split('\n')) {
      const s = l.trim().split(/\s+/);
      if (s[0] === 'v') v.push(s.slice(1).map(Number));
      else if (s[0] === 'vt') t.push(s.slice(1).map(Number));
      else if (s[0] === 'vn') n.push(s.slice(1).map(Number));
      else if (s[0] === 'f') for (const c of s.slice(1)) { const [a, b, d] = c.split('/').map(x => +x - 1); P.push(...v[a]); U.push(...t[b]); N.push(...n[d]); }
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(P, 3));
    g.setAttribute('uv', new THREE.Float32BufferAttribute(U, 2));
    g.setAttribute('normal', new THREE.Float32BufferAttribute(N, 3));
    const r = new THREE.WebGLRenderer({ antialias: true }); r.setSize(1000, 1000); r.setPixelRatio(2);
    r.outputColorSpace = THREE.SRGBColorSpace; document.body.appendChild(r.domElement);
    const scene = new THREE.Scene(); scene.background = new THREE.Color(0x2a2533);
    const map = await new THREE.TextureLoader().loadAsync(tex); map.colorSpace = THREE.SRGBColorSpace; map.anisotropy = 8;
    const mesh = new THREE.Mesh(g, new THREE.MeshStandardMaterial({ map, metalness: 0.35, roughness: 0.35 }));
    scene.add(mesh);
    // simple mannequin neck + chest for context (Roblox-ish blocky torso)
    const skin = new THREE.MeshStandardMaterial({ color: 0x8c7fa3, roughness: 0.8 });
    const torso = new THREE.Mesh(new THREE.BoxGeometry(2, 2, 1), skin); torso.position.set(0, -1, 0); scene.add(torso);
    const neck = new THREE.Mesh(new THREE.CylinderGeometry(0.33, 0.36, 0.5, 24), skin); neck.position.set(0, 0.25, -0.02); scene.add(neck);
    scene.add(new THREE.HemisphereLight(0xffffff, 0x443355, 1.4));
    const key = new THREE.DirectionalLight(0xffffff, 2.4); key.position.set(-2, 3, -4); scene.add(key);
    const rim = new THREE.DirectionalLight(0xffd0e8, 1.2); rim.position.set(3, 1, -2); scene.add(rim);
    const cam = new THREE.PerspectiveCamera(30, 1, 0.1, 50); cam.position.set(0.8, 0.6, -3.4); cam.lookAt(0, -0.35, 0);
    r.render(scene, cam);
  }, { obj, tex });
  await page.screenshot({ path: path.join(dir, 'preview.png') });
  await browser.close();
})();
