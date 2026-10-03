// Twitch chat overlay using Twitch's anonymous read-only IRC-over-WebSocket.
function argb(v) {
  v = Number(v) >>> 0;
  return 'rgba(' + ((v >> 16) & 255) + ',' + ((v >> 8) & 255) + ',' + (v & 255) + ',' + ((v >>> 24) / 255) + ')';
}

function parseTags(raw) {
  var tags = {};
  raw.split(';').forEach(function (kv) { var i = kv.indexOf('='); tags[kv.slice(0, i)] = kv.slice(i + 1); });
  return tags;
}

/** Parses one IRC line; returns {nick, color, text} for chat messages. */
function parseLine(line) {
  var tags = {};
  if (line[0] === '@') { var sp = line.indexOf(' '); tags = parseTags(line.slice(1, sp)); line = line.slice(sp + 1); }
  var m = /^:([^!]+)![^ ]+ PRIVMSG #[^ ]+ :(.*)$/.exec(line);
  if (!m) return null;
  return { nick: tags['display-name'] || m[1], color: tags.color || '#9ea3b0', text: m[2], at: Date.now() };
}

obstablet.registerSource('chat', {
  create: function (ctx) {
    var g = ctx.canvas.getContext('2d');
    var messages = [];
    var ws = null, channel = '', status = '';

    function connect() {
      if (ws) { ws.onclose = null; ws.close(); ws = null; }
      channel = String(ctx.settings.channel || '').trim().toLowerCase().replace(/^#/, '');
      messages = [];
      if (!channel) { status = 'Set a channel in the source properties'; draw(); return; }
      status = 'Connecting to #' + channel + '…'; draw();
      ws = new WebSocket('wss://irc-ws.chat.twitch.tv:443');
      ws.onopen = function () {
        ws.send('CAP REQ :twitch.tv/tags');
        ws.send('PASS SCHMOOPIIE');
        ws.send('NICK justinfan' + Math.floor(10000 + Math.random() * 80000));
        ws.send('JOIN #' + channel);
        status = ''; draw();
      };
      ws.onmessage = function (e) {
        String(e.data).split('\r\n').forEach(function (line) {
          if (!line) return;
          if (line.indexOf('PING') === 0) { ws.send('PONG' + line.slice(4)); return; }
          var msg = parseLine(line);
          if (msg) { messages.push(msg); if (messages.length > 100) messages.shift(); draw(); }
        });
      };
      ws.onclose = function () { status = 'Disconnected, retrying…'; draw(); setTimeout(connect, 5000); };
    }

    function wrap(text, width) {
      var words = text.split(' '), lines = [], cur = '';
      words.forEach(function (w) {
        var t = cur ? cur + ' ' + w : w;
        if (g.measureText(t).width > width && cur) { lines.push(cur); cur = w; } else { cur = t; }
      });
      if (cur) lines.push(cur);
      return lines;
    }

    function draw() {
      var s = ctx.settings, fs = Number(s.fontSize) || 30, pad = 16;
      g.clearRect(0, 0, ctx.width, ctx.height);
      g.fillStyle = argb(s.background);
      g.fillRect(0, 0, ctx.width, ctx.height);
      g.font = fs + 'px sans-serif';
      g.textBaseline = 'top';
      if (status) { g.fillStyle = '#ffffff'; g.fillText(status, pad, pad); ctx.present(); return; }

      var fade = Number(s.fadeAfter) || 0, now = Date.now();
      var shown = messages.filter(function (m) { return !fade || now - m.at < fade * 1000; })
        .slice(-Math.max(1, Number(s.maxLines) || 12));
      // Lay out from the bottom up.
      var y = ctx.height - pad;
      for (var i = shown.length - 1; i >= 0 && y > 0; i--) {
        var m = shown[i];
        var nick = m.nick + ': ';
        g.font = 'bold ' + fs + 'px sans-serif';
        var nickW = g.measureText(nick).width;
        g.font = fs + 'px sans-serif';
        var lines = wrap(m.text, ctx.width - pad * 2 - nickW);
        y -= lines.length * fs * 1.25;
        g.font = 'bold ' + fs + 'px sans-serif';
        g.fillStyle = m.color;
        g.fillText(nick, pad, y);
        g.font = fs + 'px sans-serif';
        g.fillStyle = '#ffffff';
        lines.forEach(function (l, k) { g.fillText(l, pad + nickW, y + k * fs * 1.25); });
        y -= fs * 0.35;
      }
      ctx.present();
    }

    connect();
    ctx.fadeTimer = setInterval(function () { if (Number(ctx.settings.fadeAfter)) draw(); }, 1000);
    ctx.onSettings(function (s) {
      if (String(s.channel || '').trim().toLowerCase().replace(/^#/, '') !== channel) connect(); else draw();
    });
    ctx.close = function () { if (ws) { ws.onclose = null; ws.close(); } };
  },
  destroy: function (ctx) { clearInterval(ctx.fadeTimer); ctx.close(); }
});

// Exposed for tests.
if (typeof module !== 'undefined') module.exports = { parseLine: parseLine };
