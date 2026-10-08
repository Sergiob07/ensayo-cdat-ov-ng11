#!/usr/bin/env node
// Auditoría de dependencias con excepciones aprobadas.
// Falla solo si aparece una vulnerabilidad alta o crítica que no tiene una excepción vigente.
// Va en el repositorio: .github/scripts/auditar-dependencias.js
//
// Uso: node auditar-dependencias.js npm|composer [archivo-de-excepciones]
//
// Archivo de excepciones (por defecto .github/auditoria-excepciones.json):
//   { "excepciones": [ { "id": "GHSA-xxxx-xxxx-xxxx", "motivo": "...", "aprobado_por": "...", "vence": "AAAA-MM-DD" } ] }
// Funciona con npm 6 (Angular 11 y anteriores), npm 7 o superior y Composer 2.
'use strict';

const { spawnSync } = require('child_process');
const fs = require('fs');

const gestor = process.argv[2];
const rutaExcepciones = process.argv[3] || '.github/auditoria-excepciones.json';
const SEVERIDADES = ['high', 'critical'];
const hoy = new Date().toISOString().slice(0, 10);

if (gestor !== 'npm' && gestor !== 'composer') {
  console.error('Uso: node auditar-dependencias.js npm|composer [archivo-de-excepciones]');
  process.exit(2);
}

function ejecutar(comando, argumentos) {
  // En Windows, npm y composer son scripts .cmd/.bat: se invocan a través de la shell.
  const r = spawnSync(comando, argumentos, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, shell: process.platform === 'win32' });
  if (r.error) throw r.error;
  try {
    return JSON.parse(r.stdout);
  } catch (e) {
    console.error(r.stdout || r.stderr);
    throw new Error(`No se pudo leer la salida de ${comando} audit`);
  }
}

function idDe(texto) {
  const m = /GHSA-[0-9a-z]{4}-[0-9a-z]{4}-[0-9a-z]{4}/i.exec(texto || '');
  return m ? m[0] : null;
}

// Hallazgos altos o críticos: id → { severidad, paquete, titulo }
const hallazgos = new Map();
function agregar(id, severidad, paquete, titulo) {
  if (!id || !SEVERIDADES.includes(severidad)) return;
  if (!hallazgos.has(id)) hallazgos.set(id, { severidad, paquete, titulo });
}

if (gestor === 'npm') {
  const mayor = parseInt(spawnSync('npm', ['-v'], { encoding: 'utf8', shell: process.platform === 'win32' }).stdout, 10);
  const datos = ejecutar('npm', mayor >= 7 ? ['audit', '--json', '--omit=dev'] : ['audit', '--json', '--production']);
  if (datos.advisories) {
    // npm 6
    for (const a of Object.values(datos.advisories)) {
      agregar(idDe(a.url) || `npm-${a.id}`, a.severity, a.module_name, a.title);
    }
  } else {
    // npm 7 o superior
    for (const [paquete, v] of Object.entries(datos.vulnerabilities || {})) {
      for (const via of v.via || []) {
        if (typeof via === 'object') agregar(idDe(via.url) || `npm-${via.source}`, via.severity, via.name || paquete, via.title);
      }
    }
  }
} else {
  const datos = ejecutar('composer', ['audit', '--format=json', '--no-dev', '--abandoned=report']);
  for (const [paquete, lista] of Object.entries(datos.advisories || {})) {
    for (const a of lista) {
      // Composer antiguo no informa la severidad: se trata como alta para no dejarla pasar.
      agregar(idDe(a.link) || a.cve || a.advisoryId, (a.severity || 'high').toLowerCase(), paquete, a.title);
    }
  }
}

let excepciones = [];
if (fs.existsSync(rutaExcepciones)) {
  excepciones = JSON.parse(fs.readFileSync(rutaExcepciones, 'utf8')).excepciones || [];
}
const vigentes = new Map(excepciones.filter((e) => !e.vence || e.vence >= hoy).map((e) => [e.id, e]));

const nuevas = [];
for (const [id, h] of hallazgos) {
  const linea = `${id} · ${h.severidad} · ${h.paquete} · ${h.titulo}`;
  const ex = vigentes.get(id);
  if (!ex) {
    nuevas.push(linea);
    console.log(`::error::Vulnerabilidad sin excepción aprobada: ${linea}`);
  } else {
    console.log(`::warning::Excepción aprobada por ${ex.aprobado_por || 'sin dato'} (vence ${ex.vence || 'sin fecha'}): ${linea}`);
  }
}
for (const e of excepciones) {
  if (e.vence && e.vence < hoy) console.log(`::warning::La excepción ${e.id} venció el ${e.vence}; ya no se tiene en cuenta.`);
  else if (!hallazgos.has(e.id)) console.log(`::notice::La excepción ${e.id} ya no es necesaria; se puede eliminar del archivo.`);
}

console.log(`Altas o críticas: ${hallazgos.size} · con excepción vigente: ${hallazgos.size - nuevas.length} · sin excepción: ${nuevas.length}`);
process.exit(nuevas.length ? 1 : 0);
