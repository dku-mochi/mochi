import * as THREE from "three";

/*
 * XY 평면 라운드 사각형 Shape — 얇은 카드 백킹의 extrude 용.
 * drei RoundedBox 는 radius 가 최소 변(두께)의 절반으로 클램프되어, 두께 0.035 카드에서
 * 코너 반경이 0.0175 로 잘린다. 앞면(반경 0.1+)의 둥근 코너 밖으로 각진 백킹이
 * 삐져나와 회색 귀처럼 보이던 원인 — extrude 는 XY 반경이 두께와 독립이라 해결된다.
 */
export function roundedRectShape(w: number, h: number, r: number): THREE.Shape {
  const s = new THREE.Shape();
  const x = -w / 2;
  const y = -h / 2;
  s.moveTo(x + r, y);
  s.lineTo(x + w - r, y);
  s.quadraticCurveTo(x + w, y, x + w, y + r);
  s.lineTo(x + w, y + h - r);
  s.quadraticCurveTo(x + w, y + h, x + w - r, y + h);
  s.lineTo(x + r, y + h);
  s.quadraticCurveTo(x, y + h, x, y + h - r);
  s.lineTo(x, y + r);
  s.quadraticCurveTo(x, y, x + r, y);
  s.closePath();
  return s;
}
