// Clock overlay. Each source instance gets a canvas; draw on it and call
// ctx.present() to show the result.
function argb(v) {
  v = Number(v) >>> 0;
  return 'rgba(' + ((v >> 16) & 255) + ',' + ((v >> 8) & 255) + ',' + (v & 255) + ',' + ((v >>> 24) / 255) + ')';
}

obstablet.registerSource('clock', {
  create: function (ctx) {
    var g = ctx.canvas.getContext('2d');
    function draw() {
      var s = ctx.settings, now = new Date();
      var h = now.getHours(), m = now.getMinutes(), sec = now.getSeconds();
      var suffix = '';
      if (s.format === '12h') { suffix = h < 12 ? ' AM' : ' PM'; h = h % 12 || 12; }
      var pad = function (n) { return (n < 10 ? '0' : '') + n; };
      var time = (s.format === '12h' ? h : pad(h)) + ':' + pad(m) + (s.seconds ? ':' + pad(sec) : '') + suffix;

      g.clearRect(0, 0, ctx.width, ctx.height);
      g.fillStyle = argb(s.background);
      var r = 28;
      g.beginPath();
      g.moveTo(r, 0); g.arcTo(ctx.width, 0, ctx.width, ctx.height, r); g.arcTo(ctx.width, ctx.height, 0, ctx.height, r);
      g.arcTo(0, ctx.height, 0, 0, r); g.arcTo(0, 0, ctx.width, 0, r); g.fill();

      g.fillStyle = argb(s.color);
      g.textAlign = 'center';
      g.textBaseline = 'middle';
      g.font = 'bold ' + (s.date ? 120 : 150) + 'px sans-serif';
      g.fillText(time, ctx.width / 2, s.date ? ctx.height * 0.42 : ctx.height / 2);
      if (s.date) {
        g.font = '44px sans-serif';
        g.fillText(now.toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'long' }),
          ctx.width / 2, ctx.height * 0.82);
      }
      ctx.present();
    }
    draw();
    ctx.timer = setInterval(draw, 500);
    ctx.onSettings(draw);
  },
  destroy: function (ctx) { clearInterval(ctx.timer); }
});
