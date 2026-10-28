# Third-party notices

TinyStats has no third-party package or binary dependencies. Apple system frameworks are provided by macOS.

The AppleSMC wire layout, commands, scalar format behavior and sensor key conventions were researched against Stats by Serhiy Mytrovtsiy. `Sources/CTinyStats/SMC.c` is an independently written C adapter using these protocol details; attribution is retained here for the researched layout and conventions.

Reference: https://github.com/exelban/stats (SMC/smc.swift and Modules/Sensors/values.swift).

The optional IOReport adapter and residency calculations are independently written. Private function signatures, channel names and pmgr frequency-table conventions were also researched against Stats (Modules/CPU/readers.swift, Modules/Sensors/readers.swift, Kit/plugins/SystemKit.swift). The MIT attribution below covers this protocol research as well. No Stats package or binary is embedded.

The native process-traffic control socket, strict byte decoder and accounting state machine are independently written from Apple's open XNU ntstat.h, ntstat.c and in_stat.h protocol facts. Those research sources are under APSL 2.0 ([ntstat.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/ntstat.h), [ntstat.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/net/ntstat.c), [in_stat.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/netinet/in_stat.h)); their headers/implementation are not copied or embedded. The app links no private NetworkStatistics framework. No proprietary iStat Menus code/assets are embedded.

MIT License

Copyright (c) 2019 Serhiy Mytrovtsiy

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.


## Optional MET Norway forecast data

When explicitly enabled, weather data is requested from [MET Norway Locationforecast](https://api.met.no/weatherapi/locationforecast/2.0/documentation). Data from MET Norway is available under [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) and NLOD 2.0; see the [provider licensing policy](https://api.met.no/doc/License). TinyStats displays and converts selected forecast variables and derives daily ranges from available timestamp samples; these ranges may be partial. This is not an endorsement by MET Norway. No provider icons, code or real forecast dataset is bundled; condition symbols use native SF Symbols. Forecast results remain in memory.

Process identity layout facts for optional network bundle grouping also come from pinned Apple XNU sources (APSL 2.0): [proc_info_private.h](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/sys/proc_info_private.h), [proc_info.c](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/kern/proc_info.c) and [ntstat.c](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/net/ntstat.c). The narrow ABI projection and path parser are original; no Apple implementation is copied or linked.
