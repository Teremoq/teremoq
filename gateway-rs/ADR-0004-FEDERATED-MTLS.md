# ADR-0004: mTLS para federación privada Gateway → relay

- Estado: aceptada para Sprint 1 / Task 02
- Fecha: 2026-08-25
- Owner: Distribución y Seguridad del Gateway

## Contexto

El publisher Teremoq abre una conexión saliente QUIC/WebTransport/MoQT hacia un relay privado. La autenticación TLS previa sólo verificaba el certificado servidor y admitía un bypass de desarrollo. La federación necesita que el Gateway valide al relay contra una CA explícita y presente una identidad cliente antes de enviar setup MoQT. Esta decisión establece autenticación de nodo; no autoriza namespaces ni completa una arquitectura Zero-Trust.

El wire protocol continúa siendo MoQT draft-16 y el ALPN continúa siendo el que seleccionan `moq-native-ietf` y `moq-transport`. No se modifica QUIC, WebTransport, MoQT, Tracks, Groups, Objects ni payloads.

## Reconocimiento upstream

Se revisó íntegramente el checkout oficial [`cloudflare/moq-rs`](https://github.com/cloudflare/moq-rs) en `bf87128affd316463e5dcc7599a45001f222b6de` (merge de PR #156, 2026-08-18), junto con las releases fijadas:

- `moq-native-ietf 0.10.0`, release de la transición draft-16.
- `moq-transport 0.16.1`, release draft-16 con el fix de cierre de subgroup a mitad de Object.
- `moq-relay-ietf 0.7.25`, relay de la misma línea draft-16.
- PR #170, registrada en los changelogs upstream como el rewrite draft-16.

En `moq-native-ietf/src/tls.rs`, `tls::Args::load()`:

1. Usa raíces del sistema cuando `Args.root` está vacío.
2. Construye el cliente con `with_no_client_auth()`.
3. Usa `Args.cert` y `Args.key` únicamente para `ServeCerts`, el resolver del certificado servidor.
4. Construye el servidor con `with_no_client_auth()`.
5. Ofrece `dangerous().set_certificate_verifier(...)` cuando `disable_verify` está activo.

Por ello, rellenar `Args.cert`/`Args.key` no presenta certificado cliente. `tls::Config` sí es pública y contiene `client: rustls::ClientConfig`, `server: Option<rustls::ServerConfig>` y `fingerprints`. `quic::Config::new` y `quic::Endpoint::new` también son APIs públicas, por lo que el gap puede integrarse sin copiar o parchear upstream.

El 2026-08-25 se buscaron en issues y PRs, abiertos y cerrados, los términos `mTLS`, `client certificate`, `with_client_auth_cert`, `ClientCertVerifier` y `WebPkiClientVerifier`; la API de búsqueda de GitHub devolvió cero resultados en el repositorio. No existe en esta revisión una API de argumentos mTLS que satisfaga el contrato.

También se verificaron las APIs oficiales:

- [`rustls 0.23.43`](https://docs.rs/rustls/0.23.43/rustls/): `builder_with_provider`, `with_protocol_versions`, `with_root_certificates`, `with_client_auth_cert`, `with_client_cert_verifier` y `WebPkiClientVerifier`.
- [`rustls-pki-types 1.15.1`](https://docs.rs/rustls-pki-types/1.15.1/rustls_pki_types/pem/trait.PemObject.html): `PemObject`, `pem_slice_iter` y tipos DER para certificados y claves PKCS#1, PKCS#8 o SEC1.

## Threat model cubierto

La decisión cubre:

- Relay impostor o MITM cuyo certificado no encadena a la CA configurada o cuyo hostname/IP no está en SAN.
- Gateway anónimo que no presenta certificado cliente.
- Gateway firmado por una CA distinta a la allowlist del relay.
- Certificados fuera de vigencia o sin EKU cliente/servidor apropiada.
- Configuración local parcial, PEM inválido, cert/key incompatible, clave con permisos Unix de grupo/otros o clave referenciada mediante symlink.
- Relectura o sustitución accidental de credenciales entre reconexiones: la identidad se carga una sola vez antes de listeners y el endpoint se reutiliza.

No cubre robo de una clave válida, autorización por identidad o namespace, revocación, protección del filesystem fuera de los checks explícitos, compromiso de CA, attestation del nodo ni rotación sin reinicio.

## Alternativas

1. **Usar sólo `tls::Args`.** Rechazada: no presenta certificado cliente y permite raíces del sistema o bypass.
2. **Añadir `wtransport`.** Rechazada: no implementa MoQT y añadiría otra integración WebTransport sin cerrar el gap de la API fijada.
3. **Añadir otro stack QUIC/TLS.** Rechazada: duplicaría transporte, ALPN, tuning y superficie de interoperabilidad.
4. **Fork local de `moq-rs`.** Rechazada: crea coste de sincronización y divergencia cuando las APIs públicas actuales permiten inyectar `rustls::ClientConfig`.
5. **Esperar una release futura.** Rechazada para esta tarea: mantiene publicación anónima y bypass mientras existe una integración pequeña, verificable y reversible.
6. **Adaptador sobre rustls y las configuraciones públicas upstream.** Elegida.

## Decisión

`security::mtls` es un adaptador específico del publisher Teremoq. Lee con `tokio::fs`, usa los iteradores PEM de `rustls-pki-types`, construye `RootCertStore`, fija `rustls::crypto::ring::default_provider()` y habilita exclusivamente TLS 1.3. El cliente se finaliza con `with_client_auth_cert`; no usa `dangerous()`, raíces de sistema, fallback, verificadores propios ni parsing X.509 propio.

El resultado se inserta en `moq_native_ietf::tls::Config { client, server: None, fingerprints: [] }`, después en `moq_native_ietf::quic::Config`, y finalmente en `moq_native_ietf::quic::Endpoint`. La publicación y las reconexiones siguen usando el `Client` oficial. Esto es código de integración y política de carga, no una biblioteca TLS: no implementa record layer, handshake, PKIX, hostname, firmas, QUIC ni WebTransport.

La identidad y el socket se preparan antes de `gateway_started`, GStreamer, SRT y tasks críticas. Un error local es fatal y no entra en backoff. Un fallo remoto conserva el presupuesto, backoff y jitter previos. El endpoint preparado y su identidad se reutilizan en cada reconexión.

## Relay de desarrollo y separación de interfaces

- UDP/4433 conserva `dev_moq_relay`: laboratorio browser/playback, sin cambio de comportamiento.
- UDP/4443 usa `dev_mtls_moq_relay`: laboratorio de integración federada loopback, certificado servidor configurado y certificado cliente obligatorio.

El relay 4443 reutiliza `moq-relay-ietf`, el `Coordinator` upstream, `rustls::ServerConfig` y `WebPkiClientVerifier`. Sólo resuelve `/publish`; `/watch` y cualquier otra ruta se rechazan. `moq-native-ietf` configura `max_idle_timeout` QUIC de 10 s para cada conexión, pero éste es un timeout por inactividad y **no** un deadline monotónico absoluto del handshake. Los handshakes pendientes se gestionan concurrentemente mediante un `FuturesUnordered` upstream sin límite público configurable en la revisión fijada. El ejemplo no genera certificados y no es el servicio federado productivo final.

`moq_native_ietf::tls::Config` exige también un campo cliente aunque este endpoint sólo acepte conexiones. El ejemplo construye ese valor interno con `with_no_client_auth()` porque el `Coordinator` nunca devuelve una ruta remota; no se expone ni se usa para una conexión saliente. La política de federación del Gateway no comparte ese valor: siempre usa el `ClientConfig` mTLS preparado por `security::mtls`.

## Concurrencia y aislamiento

Las lecturas PKI sólo ocurren en startup. No existe lock síncrono alrededor de `.await`. Los handshakes remotos están sujetos al idle timeout de QUIC y se procesan de forma concurrente por el endpoint upstream, pero no existe un límite explícito de handshakes pendientes ni un deadline absoluto de handshake. Los fallos no comparten cola con ingesta o scheduler. El retry loop del publisher conserva backoff exponencial acotado, jitter y presupuesto móvil; un fallo TLS no produce retry agresivo.

## Licencias y dependencias

- `rustls 0.23.43`: Apache-2.0 OR ISC OR MIT; repositorio `rustls/rustls`.
- `rustls-pki-types 1.15.1`: MIT OR Apache-2.0; repositorio `rustls/pki-types`.
- `moq-rs`: MIT OR Apache-2.0.

Las versiones rustls ya existían transitivamente en `Cargo.lock`; pasan a ser directas porque Teremoq usa sus APIs. No se añade `wtransport`, OpenSSL, parser ASN.1/X.509, segunda biblioteca TLS, segundo transporte QUIC ni dependencia Git adicional.

## Limitaciones

- No hay CRL, OCSP ni distribución offline de listas de revocación; una identidad emitida sigue válida hasta expirar o hasta rotar la CA/configuración y reiniciar.
- TLS autentica la cadena, EKU, vigencia y posesión de clave; el `Coordinator` de laboratorio no transforma esa identidad en permisos por namespace.
- La autorización por identidad y namespace sigue bloqueada por la API pública
  upstream; `ADR-0005-FEDERATED-AUTHORIZATION.md` registra la evidencia, los
  riesgos y el contrato mínimo requerido. No debe inferirse autorización de un
  certificado válido, IP, SNI o path.
- Los tests rustls↔rustls demuestran integración local, rechazo y aislamiento, no interoperabilidad mTLS universal. Falta un peer QUIC/WebTransport independiente que exija certificado cliente.
- La evidencia externa MoQT previa permanece parcial 7/8 y no se reinterpreta como evidencia mTLS.
- La rotación de identidad requiere reinicio fail-closed en esta tarea.

## Estrategia de salida

En cada actualización atómica de `moq-native-ietf`/`moq-transport` se revisarán `tls::Args`, `tls::Config` y sus changelogs. Cuando una release draft-compatible ofrezca una API pública que: (a) cargue cadena cliente completa, (b) exija una única clave, (c) use raíces explícitas sin fallback, (d) preserve TLS 1.3 y verificación de hostname, y (e) permita preparar el endpoint antes de listeners, se reemplazará `security::mtls` por esa API. Los mismos tests negativos, de Objects y concurrencia serán la puerta de retirada; después se eliminarán las dependencias directas que ya no se usen.
