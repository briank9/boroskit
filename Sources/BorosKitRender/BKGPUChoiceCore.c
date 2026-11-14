// BorosKitRender: BKGPUChoiceCore - see include/BKGPUChoiceCore.h for the rules and PORTING NOTES.
// Original BorosKit code written for this project; contains no third-party code.

#include "BKGPUChoiceCore.h"

#include <string.h>

static const char *BKGPUName(const BKGPUAdapterDesc *a)
{
    return a->name ? a->name : "";
}

// What: rank of the adapter's kind for Automatic (smaller = better).
// Unknown kind (Metal) counts as discrete unless the card says it is low-power.
static int BKGPUKindRank(const BKGPUAdapterDesc *a)
{
    switch (a->kind) {
        case BKGPUKindDiscrete:   return 0;
        case BKGPUKindIntegrated: return 1;
        case BKGPUKindVirtual:    return 2;
        case BKGPUKindCPU:        return 3;
        default:                  return a->isLowPower ? 1 : 0;
    }
}

int BKGPUCompareForAutomatic(const BKGPUAdapterDesc *a, const BKGPUAdapterDesc *b)
{
    // 1. real GPU before software renderer
    int aSoft = a->kind == BKGPUKindCPU, bSoft = b->kind == BKGPUKindCPU;
    if (aSoft != bSoft) return aSoft - bSoft;
    // 2. built-in before removable
    int aRem = a->isRemovable != 0, bRem = b->isRemovable != 0;
    if (aRem != bRem) return aRem - bRem;
    // 3. discrete / high-performance first
    int aKind = BKGPUKindRank(a), bKind = BKGPUKindRank(b);
    if (aKind != bKind) return aKind - bKind;
    // 4. more memory first
    if (a->memoryBytes != b->memoryBytes) return a->memoryBytes > b->memoryBytes ? -1 : 1;
    // 5. deterministic tie-break
    if (a->handle != b->handle) return a->handle < b->handle ? -1 : 1;
    int byName = strcmp(BKGPUName(a), BKGPUName(b));
    return byName < 0 ? -1 : (byName > 0 ? 1 : 0);
}

// What: best adapter by the Automatic order, among all (nameFilter NULL) or only those whose
// name equals nameFilter. -1 when none qualifies.
static int BKGPUBest(const BKGPUAdapterDesc *adapters, int count, const char *nameFilter)
{
    int best = -1;
    for (int i = 0; i < count; i++) {
        if (nameFilter && strcmp(BKGPUName(&adapters[i]), nameFilter) != 0) continue;
        // strictly better only, so equal adapters keep the earlier list position
        if (best < 0 || BKGPUCompareForAutomatic(&adapters[i], &adapters[best]) < 0) best = i;
    }
    return best;
}

int BKGPUChooseAdapter(const BKGPUAdapterDesc *adapters, int count, const char *preferredName,
                       BKGPUChoiceStatus *status)
{
    if (adapters == NULL || count <= 0) {
        if (status) *status = BKGPUChoiceNone;
        return -1;
    }
    if (preferredName && preferredName[0] != '\0') {
        int named = BKGPUBest(adapters, count, preferredName);
        if (named >= 0) {
            if (status) *status = BKGPUChoiceByName;
            return named;
        }
        if (status) *status = BKGPUChoicePreferredMissing;
        return BKGPUBest(adapters, count, NULL);
    }
    if (status) *status = BKGPUChoiceAutomatic;
    return BKGPUBest(adapters, count, NULL);
}
