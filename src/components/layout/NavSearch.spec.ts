import { shallowMount, flushPromises } from "@vue/test-utils";
import { reactive } from "vue";
import { beforeEach, expect, it, vi } from "vitest";
import NavSearch from "./NavSearch.vue";

const mocks = vi.hoisted(() => ({
  history: vi.fn(),
  push: vi.fn(),
  play: vi.fn(),
}));
vi.mock("@/stores/data", () => ({
  useDataStore: () => ({ searchHistory: [], addSearchHistory: mocks.history }),
}));
vi.mock("@/stores/status", () => ({ useStatusStore: () => reactive({ searchOpen: true }) }));
vi.mock("vue-router", () => ({ useRouter: () => ({ push: mocks.push }) }));
vi.mock("vue-i18n", () => ({ useI18n: () => ({ t: (key: string) => key, locale: "zh-CN" }) }));
vi.mock("@vueuse/core", () => ({
  useDebounceFn: (fn: unknown) => fn,
  useResizeObserver: vi.fn(),
}));
vi.mock("@/apis/search/hot", () => ({ getHotSearches: async () => [] }));
vi.mock("@/apis/search/suggest", () => ({
  getSearchSuggest: async () => ({
    songs: [{ id: 1, name: "特别的人", artist: "方大同" }],
    artists: [],
    albums: [],
    playlists: [],
  }),
}));
vi.mock("@/apis/song/netease", () => ({
  songsByIds: async () => [{ id: "1", title: "特别的人" }],
}));
vi.mock("@/core/player", () => ({ playNow: mocks.play }));
vi.mock("@/utils/navigate", () => ({
  navigateToAlbum: vi.fn(),
  navigateToArtist: vi.fn(),
  navigateToPlaylist: vi.fn(),
}));
vi.mock("@/utils/link", () => ({ parseMusicLink: () => null }));
vi.mock("@/utils/config", () => ({ isIOS: true }));
vi.mock("~icons/lucide/music", () => ({ default: {} }));
vi.mock("~icons/lucide/user", () => ({ default: {} }));
vi.mock("~icons/lucide/disc", () => ({ default: {} }));
vi.mock("~icons/lucide/list-music", () => ({ default: {} }));
vi.mock("~icons/lucide/audio-waveform", () => ({ default: {} }));

beforeEach(() => vi.clearAllMocks());

it("点击歌曲建议记录完整歌名，而不是模糊输入", async () => {
  const wrapper = shallowMount(NavSearch, { global: { renderStubDefaultSlot: true } });
  const vm = wrapper.vm as unknown as {
    searchQuery: string;
    onPickSuggest: (kind: string, id: number, name: string) => void;
  };
  vm.searchQuery = "特别";
  await flushPromises();
  vm.onPickSuggest("song", 1, "特别的人");
  await flushPromises();
  expect(mocks.history).toHaveBeenCalledExactlyOnceWith("特别的人");
  expect(mocks.play).toHaveBeenCalledWith({ id: "1", title: "特别的人" });
  wrapper.unmount();
});

it("直接提交搜索仍记录输入词", async () => {
  const wrapper = shallowMount(NavSearch, { global: { renderStubDefaultSlot: true } });
  const vm = wrapper.vm as unknown as { searchQuery: string; onSubmit: () => void };
  vm.searchQuery = " 特别 ";
  await flushPromises();
  vm.onSubmit();
  expect(mocks.history).toHaveBeenCalledExactlyOnceWith("特别");
  expect(mocks.push).toHaveBeenCalledWith({ name: "search", query: { q: "特别" } });
  wrapper.unmount();
});
