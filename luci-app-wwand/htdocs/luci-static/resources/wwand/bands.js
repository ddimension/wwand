'use strict';
'require baseclass';

/* Shared cellular band/frequency helpers for the wwand LuCI packages
   (status page and the qmi proto handler). Single source of truth so the
   band tables are not copy-pasted across resources.

   E-UTRA (LTE) downlink band table: [band, earfcn_low, earfcn_high, fdl_low_mhz].
   Frequency = fdl_low + 0.1*(earfcn - earfcn_low). Covers the common FDD/TDD
   bands; unknown EARFCNs fall through to null. */
var LTE_BANDS = [
	[1,0,599,2110],[2,600,1199,1930],[3,1200,1949,1805],[4,1950,2399,2110],
	[5,2400,2649,869],[7,2750,3449,2620],[8,3450,3799,925],[12,5010,5179,729],
	[13,5180,5279,746],[14,5280,5379,758],[17,5730,5849,734],[18,5850,5999,860],
	[19,6000,6149,875],[20,6150,6449,791],[21,6450,6599,1495.9],[25,8040,8689,1930],
	[26,8690,9039,859],[28,9210,9659,758],[32,9770,9919,1452],[38,37750,38249,2570],
	[40,38650,39649,2300],[41,39650,41589,2496],[42,41590,43589,3400],[43,43590,45589,3600]
];

/* NR-ARFCN -> frequency (MHz) via the FR1 global raster: F = 5 kHz * ARFCN
   for ARFCN < 600000, i.e. MHz = ARFCN/200. Band inferred by frequency. */
var NR_BANDS = [
	['n1',2110,2170],['n3',1805,1880],['n5',869,894],['n7',2620,2690],
	['n8',925,960],['n20',791,821],['n28',758,803],['n38',2570,2620],
	['n40',2300,2400],['n41',2496,2690],['n77',3300,4200],['n78',3300,3800],['n79',4400,5000]
];

return baseclass.extend({
	LTE_BANDS: LTE_BANDS,
	NR_BANDS: NR_BANDS,

	/* EARFCN -> { band: 'B<n>', mhz: <number> } or null */
	lteEarfcn: function(earfcn) {
		for (var i = 0; i < LTE_BANDS.length; i++) {
			var b = LTE_BANDS[i];
			if (earfcn >= b[1] && earfcn <= b[2])
				return { band: 'B' + b[0], mhz: (b[3] + 0.1 * (earfcn - b[1])) };
		}
		return null;
	},

	/* NR-ARFCN -> { band: 'n<n>'|null, mhz: <number> } or null */
	nrArfcn: function(arfcn) {
		if (arfcn == null)
			return null;
		var mhz = arfcn / 200, band = null;
		for (var i = 0; i < NR_BANDS.length; i++)
			if (mhz >= NR_BANDS[i][1] && mhz <= NR_BANDS[i][2]) { band = NR_BANDS[i][0]; break; }
		return { band: band, mhz: mhz };
	}
});
