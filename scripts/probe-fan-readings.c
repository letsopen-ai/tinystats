#include "CTinyStats.h"
#include <stdio.h>
int main(void) {
    ts_smc *smc = ts_smc_open();
    if (!smc) return 1;
    const char *keys[] = {"FNum", "F0Ac", "F0Mn", "F0Mx", "F0Tg", "F0Md", "F0md", "FS! ", "Ftst"};
    for (unsigned i = 0; i < sizeof(keys)/sizeof(keys[0]); ++i) {
        double value = 0;
        if (ts_smc_read(smc, keys[i], &value)) printf("%s %.3f\n", keys[i], value);
        else printf("%s unavailable\n", keys[i]);
    }
    ts_smc_close(smc);
    return 0;
}
