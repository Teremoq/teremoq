# Supply chain de modelos locales

## Estado actual

No hay un modelo seleccionado ni aprobado. `model-manifest.json` usa
`"model": null`. No se han aceptado términos de pesos, descargado artefactos ni
arrancado Ollama.

La licencia MIT del runtime Ollama no concede derechos sobre los pesos. Cada
modelo requiere una revisión separada de licencia, fuente, restricciones de uso
y distribución. La revisión técnica no sustituye una decisión jurídica cuando
los términos sean específicos, sostenibles, no comerciales o ambiguos.

## Gate fail-closed

Antes de cambiar `model` de `null` a un objeto, el owner de riesgo de modelos
debe registrar y comprobar:

- nombre exacto e inmutable;
- digest SHA-256 del artefacto local;
- fuente HTTPS canónica sin query ni fragment;
- licencia exacta de los pesos y sus obligaciones;
- tamaño en bytes y presupuesto de almacenamiento/memoria;
- contexto máximo permitido;
- fecha y rol de revisión;
- uso limitado a observación/recomendación offline;
- estado explícito `approved`.

El esquema admite un solo modelo para evitar selección implícita o mezcla entre
nombre, digest y licencia. No existe `latest`, fallback ni modelo por default.
El hash SHA-256 del propio manifiesto debe pasarse al modo `probe`, de modo que
una modificación no revisada falle antes de contactar al runtime local.

## Procedimiento futuro de revisión

1. Obtener nombre, licencia y hashes desde la fuente oficial mediante un
   proceso autorizado y separado de este bootstrap.
2. Conservar evidencia de procedencia y verificar el digest después de la
   transferencia; nunca descargar desde `init_agents.sh`.
3. Revisar licencia de pesos, datos de entrenamiento declarados, restricciones
   de uso, redistribución y obligaciones del appliance B2B.
4. Evaluar tamaño, contexto, hardware, aislamiento, calidad y resistencia a
   prompt injection usando datos sintéticos sin cliente.
5. Registrar aprobación en el manifiesto, validar con JSON Schema y revisar el
   patch por DCO.
6. Ejecutar sólo el probe loopback opt-in para comprobar presencia y digest.

Una discrepancia de nombre, digest, hash, licencia o metadata vuelve a estado
no aprobado. La disponibilidad del runtime o una respuesta correcta del modelo
no constituye autorización operativa.

## Decisiones aún necesarias

- modelo y versión concretos;
- licencia de pesos y permiso de uso/distribución B2B;
- fuente y mecanismo autorizado de adquisición;
- hardware y límites de recursos;
- parámetros de contexto y política de prompts;
- proceso de actualización, revocación y rollback;
- formato de evidencias/SBOM y owner jurídico final.

Hasta resolverlas, el bootstrap sólo valida configuración y el contrato de
recomendación permanece no ejecutable.
