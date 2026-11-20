# Nexora v7.1

v7.1: (1) precio del cliente ya no sale en $0 (customer_price ahora es security definer; volver a pegar el SQL). (2) "¿Olvidaste tu contraseña?" en App1, App2 y App3: manda un enlace al correo. En Supabase > Authentication > URL Configuration agrega la dirección de cada app en "Redirect URLs" y en "Site URL" la principal. Las cuentas viejas con correo telefono@nexora.app no reciben correos.

Cambios v7: registro con CORREO + TELÉFONO (se entra con correo y contraseña) y ruta del repartidor en cartas apiladas (un paso a la vez). Hay que volver a pegar el SQL.
- Las cuentas anteriores (telefono@nexora.app) siguen entrando escribiendo ese correo.
- Admin: update profiles set role='admin' where email='ortunoivan2000@gmail.com';

Cambios v5: repartidor EMPLEADO con sueldo diario (hay que volver a pegar el SQL), envío visible siempre y explicado (cliente), carrito editable, aviso de pagado, etiquetas verde/naranja de pago (vendedor), rutas y cobros más claros (repartidor).


SQL/nexora.sql   → UN SOLO archivo para todo. Copiar, pegar en Supabase > SQL Editor > Run (se puede volver a ejecutar).
App1/            → Nexora (cliente)            → su propio proyecto/dominio en Vercel
App2/            → Nexora Business (vendedor)  → su propio proyecto/dominio en Vercel
App3/            → Nexora Driver (repartidor)  → su propio proyecto/dominio en Vercel
App4/            → Panel de administración web (Nexora Admin)        → su propio proyecto/dominio en Vercel

1. Supabase > Authentication > Providers > Email: desactivar "Confirm email".
2. Pegar y ejecutar SQL/nexora.sql  (ESTA VERSIÓN TRAE NUEVAS TABLAS Y FUNCIONES: vuelve a ejecutarlo completo).
3. En App1/config.js, App2/config.js y App3/config.js poner SUPABASE_URL y SUPABASE_ANON_KEY (son los mismos para todas).

## Modo prueba (sin usar tus números)
Con DEMO:true aparece un botón amarillo en cada app. Entra con una cuenta de prueba ya lista
(se crea sola la primera vez) y todo es real: lo que publica el vendedor de prueba lo ve el cliente de prueba
y lo reparte el repartidor de prueba. La cuenta de prueba del repartidor sale ya aprobada y sus depósitos se confirman solos.
Sin Supabase conectado, App1 y App3 abren con datos de ejemplo para ver el diseño.
Antes de publicar: DEMO:false y borrar las cuentas de prueba (el comando está al final de nexora.sql).

## Nexora Admin (App4) · panel web de administración
- Entrar: en Supabase ejecuta una vez  update profiles set role='admin' where email='ortunoivan2000@gmail.com';  (primero regístrate en cualquier app con ese correo).
- Modo prueba: con DEMO:true el botón amarillo entra con la cuenta admin de prueba 5550000004 (se crea sola; requiere haber ejecutado nexora.sql actualizado).
  Sin Supabase conectado, el botón "Ver el panel con datos de ejemplo" abre todo con datos falsos para ver el diseño.
- Secciones: Tablero · Pedidos (asignar/liberar/entregar/cancelar, CSV) · Repartidores (aprobar con INE y rostro) · Caja y depósitos
  (confirmar comprobantes, saldos, pagos a vendedores por tarjeta) · Tiendas y productos (aprobar, cargo extra por producto) · Usuarios
  (cambiar rol, bloquear, eliminar) · Anuncios · Mapa en vivo · Chats (solo lectura) · Ajustes (cargo por producto, envío con simulador,
  % plataforma, tarjeta ON/OFF, reglas de repartidores, formas de depósito, soporte).
- Los IDs (0001…) los genera el sistema y nunca se editan.
- Antes de publicar: DEMO:false en config.js y  update settings set value='false' where key='demo_mode';  (apaga la cuenta admin de prueba).

## Nexora Driver (App3)
- Registro: nombre, teléfono, comunidad, vehículo, ubicación, foto de INE y selfie (bucket privado "kyc").
- Un repartidor real queda "en revisión" hasta que lo apruebes. Mientras no esté el panel admin:
    update profiles set driver_status='approved' where phone='NUMERO';
- Solicitudes ordenadas por cercanía; R1 = tienda más lejana de la casa del cliente (medido POR CALLES con ROUTE_API).
- Dinero: el repartidor adelanta tiendas en efectivo; al entregar se calcula lo que debe depositar
  (tiendas con tarjeta + extra por producto + porcentaje de su envío). No se le muestra como "comisión".
- Bloqueo: no puede aceptar pedidos si tiene un depósito de una jornada anterior sin pagar, o si pasa el límite (settings.debt_limit).
- Formas de depósito: settings.pay_methods, ejemplo:
    [{"type":"transfer","label":"Transferencia","detail":"CLABE 0123..."},{"type":"oxxo","label":"Tienda","detail":"Tarjeta 4000..."},{"type":"qr","label":"QR","image":"https://..."}]
- Envío (settings.delivery_mode): per_km | tiered (más lejos, más barato) | reference (punto de referencia del admin).

## Opcionales
- App2/img/ejemplo.jpg → foto de ejemplo de cómo fotografiar el negocio.
- App2/library/library.json → biblioteca de imágenes: [{"name":"Jitomate","url":"https://.../jitomate.jpg"}]
- Soporte: tabla settings, fila support_phone, con lada (ej. 522311234567).
- Tarjeta desactivada (settings.card_enabled = false); se activará desde el panel admin.
