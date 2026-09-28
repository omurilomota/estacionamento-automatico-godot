/* Estacionamento Autônomo — interações da landing (sem dependências).
 *  1. foco do iframe ao clicar na moldura (o teclado vai para o jogo);
 *  2. scrollspy da nav fixa;
 *  3. ano no rodapé.
 * O playground da rede vive em js/ml.js e se inicializa sozinho.
 */
(function () {
  'use strict';

  const frame = document.getElementById('game-frame');
  if (frame) {
    const moldura = frame.closest('.moldura');
    if (moldura) {
      moldura.addEventListener('click', () => frame.focus(), { once: true });
      frame.addEventListener('load', () => frame.focus(), { once: true });
    }
  }

  const f = document.querySelector('footer p:last-child');
  if (f) f.innerHTML = f.innerHTML.replace('feito para a banca', '© ' + new Date().getFullYear() + ' · feito para a banca');

  /* ---- scrollspy: marca o link da seção visível ---- */
  const links = Array.from(document.querySelectorAll('.nav ul a'));
  const alvos = links
    .map((a) => document.querySelector(a.getAttribute('href')))
    .filter(Boolean);
  if (links.length && alvos.length && 'IntersectionObserver' in window) {
    const visiveis = new Set();
    const obs = new IntersectionObserver(
      (entradas) => {
        entradas.forEach((e) => {
          if (e.isIntersecting) visiveis.add(e.target);
          else visiveis.delete(e.target);
        });
        let atual = null;
        visiveis.forEach((s) => {
          if (!atual || s.offsetTop < atual.offsetTop) atual = s;
        });
        links.forEach((a) => a.classList.toggle('ativo', atual !== null && a.getAttribute('href') === '#' + atual.id));
      },
      { rootMargin: '-45% 0px -50% 0px', threshold: 0 }
    );
    alvos.forEach((s) => obs.observe(s));
  }
})();
