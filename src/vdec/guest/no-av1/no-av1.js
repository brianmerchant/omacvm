// OmacVM: YouTube asks the browser which codecs it plays and picks AV1 when it
// can. Arch Linux ARM's Chromium decodes AV1 only on the CPU, VP9 and H.264 on
// the Mac's media engine (omacvm-vdec), so here AV1 is "not supported".
(() => {
  const av1 = /av01/i;
  const no = { supported: false, smooth: false, powerEfficient: false };
  for (const ms of [window.MediaSource, window.ManagedMediaSource]) {
    if (ms && ms.isTypeSupported) {
      const orig = ms.isTypeSupported.bind(ms);
      ms.isTypeSupported = (type) => !av1.test(type) && orig(type);
    }
  }
  const mc = navigator.mediaCapabilities;
  if (mc && mc.decodingInfo) {
    const orig = mc.decodingInfo.bind(mc);
    mc.decodingInfo = (c) => (c && c.video && av1.test(c.video.contentType || "")) ? Promise.resolve(no) : orig(c);
  }
  const canPlay = HTMLMediaElement.prototype.canPlayType;
  HTMLMediaElement.prototype.canPlayType = function (type) {
    return av1.test(type) ? "" : canPlay.call(this, type);
  };
})();
