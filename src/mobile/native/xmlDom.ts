import { XMLParser, XMLValidator } from "fast-xml-parser";

/** 原生后台运行在 JavaScriptCore 中，没有 DOMParser；这里只实现 lyric-kit 解析 TTML 用到的 DOM 子集 */

interface XmlAttribute {
  name: string;
  localName: string;
  prefix: string | null;
  value: string;
}

class XmlText {
  readonly nodeType = 3;
  readonly childNodes: XmlNode[] = [];
  parentNode: XmlElement | XmlDocument | null = null;
  constructor(readonly textContent: string) {}
  get nodeValue(): string {
    return this.textContent;
  }
}

type XmlNode = XmlElement | XmlText;

/** 按标签名收集后代元素，`*` 匹配全部 */
const collect = (nodes: XmlNode[], name: string, out: XmlElement[]): XmlElement[] => {
  for (const node of nodes) {
    if (node.nodeType !== 1) continue;
    if (name === "*" || node.tagName === name) out.push(node);
    collect(node.childNodes, name, out);
  }
  return out;
};

class XmlElement {
  readonly nodeType = 1;
  readonly childNodes: XmlNode[] = [];
  readonly localName: string;
  readonly prefix: string | null;
  parentNode: XmlElement | XmlDocument | null = null;

  constructor(
    readonly tagName: string,
    readonly attributes: XmlAttribute[],
  ) {
    const colon = tagName.indexOf(":");
    this.prefix = colon > 0 ? tagName.slice(0, colon) : null;
    this.localName = colon > 0 ? tagName.slice(colon + 1) : tagName;
  }

  get nodeName(): string {
    return this.tagName;
  }

  get textContent(): string {
    return this.childNodes.map((node) => node.textContent).join("");
  }

  getAttribute(name: string): string | null {
    return this.attributes.find((attr) => attr.name === name)?.value ?? null;
  }

  /**
   * 按命名空间读取属性：前缀需在本元素或祖先上声明为该命名空间
   * @param namespace - 命名空间 URI
   * @param localName - 属性本地名
   * @returns 属性值，未找到时为 null
   */
  getAttributeNS(namespace: string | null, localName: string): string | null {
    for (const attr of this.attributes) {
      if (attr.localName !== localName) continue;
      if (!attr.prefix) {
        if (!namespace) return attr.value;
        continue;
      }
      if (this.lookupNamespace(attr.prefix) === namespace) return attr.value;
    }
    return null;
  }

  getElementsByTagName(name: string): XmlElement[] {
    return collect(this.childNodes, name, []);
  }

  querySelector(name: string): XmlElement | null {
    return this.getElementsByTagName(name)[0] ?? null;
  }

  private lookupNamespace(prefix: string): string | null {
    const own = this.getAttribute(`xmlns:${prefix}`);
    if (own !== null) return own;
    return this.parentNode?.nodeType === 1 ? this.parentNode.lookupNamespace(prefix) : null;
  }
}

class XmlDocument {
  readonly nodeType = 9;
  readonly childNodes: XmlNode[] = [];

  get documentElement(): XmlElement | null {
    return (this.childNodes.find((node) => node.nodeType === 1) as XmlElement) ?? null;
  }

  get textContent(): null {
    return null;
  }

  getElementsByTagName(name: string): XmlElement[] {
    return collect(this.childNodes, name, []);
  }

  querySelector(name: string): XmlElement | null {
    return this.getElementsByTagName(name)[0] ?? null;
  }
}

const parser = new XMLParser({
  preserveOrder: true,
  ignoreAttributes: false,
  attributeNamePrefix: "",
  // TTML 中相邻 span 之间的空格是歌词内容，不能裁剪
  trimValues: false,
  parseTagValue: false,
  parseAttributeValue: false,
  ignoreDeclaration: true,
  ignorePiTags: true,
  processEntities: true,
});

type OrderedNode = Record<string, unknown> & { ":@"?: Record<string, string> };

/** fast-xml-parser 保序结果转为节点树；注释被丢弃 */
const build = (items: OrderedNode[], parent: XmlElement | XmlDocument): void => {
  for (const item of items) {
    if ("#text" in item) {
      const text = new XmlText(String(item["#text"] ?? ""));
      text.parentNode = parent;
      parent.childNodes.push(text);
      continue;
    }
    const tag = Object.keys(item).find((key) => key !== ":@");
    if (!tag || tag === "#comment") continue;
    const attributes = Object.entries(item[":@"] ?? {}).map(([name, value]) => {
      const colon = name.indexOf(":");
      return {
        name,
        value: String(value),
        prefix: colon > 0 ? name.slice(0, colon) : null,
        localName: colon > 0 ? name.slice(colon + 1) : name,
      };
    });
    const element = new XmlElement(tag, attributes);
    element.parentNode = parent;
    parent.childNodes.push(element);
    build((item[tag] as OrderedNode[]) ?? [], element);
  }
};

/** 与浏览器 DOMParser 相同的入口；XML 无效时返回带 parsererror 元素的文档 */
export class NativeDOMParser {
  parseFromString(text: string): XmlDocument {
    const doc = new XmlDocument();
    if (XMLValidator.validate(text) !== true) {
      const error = new XmlElement("parsererror", []);
      error.parentNode = doc;
      doc.childNodes.push(error);
      return doc;
    }
    build(parser.parse(text) as OrderedNode[], doc);
    return doc;
  }
}
