//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

/**
 * Tests for the accessible name and description computation (`accname.ts`).
 *
 * This suite mirrors one-for-one the Swift Testing suite in
 * `Tests/SharedTests/Publication/Services/Content/Iterators/HTMLAccessibilityPropertiesTests.swift`
 * — keep the test names aligned so the two can be diffed by eye.
 */

import {
  computeAccessibilityProperties,
  findFigureCaption,
} from "../src/accname";

/** Sets the document body to `html` and computes the accessibility
 * properties of the first `img` or `svg` element. */
function compute(html: string) {
  document.body.innerHTML = html;
  const element = document.body.querySelector("img, svg")!;
  return computeAccessibilityProperties(element);
}

describe("computeAccessibilityProperties", () => {
  describe("accessible name", () => {
    test("ariaLabelledbyResolvesMultipleIDsSkippingMissingOnes", () => {
      const result = compute(`
        <p id="l1">Hello</p><p id="l2">World</p>
        <img src="a.jpg" aria-labelledby="l1 missing l2"/>
      `);
      expect(result.name).toBe("Hello World");
    });

    test("ariaLabelledbyWithAllMissingIDsFallsThroughToAriaLabel", () => {
      const result = compute(`
        <img src="a.jpg" aria-labelledby="nope" aria-label="Label"/>
      `);
      expect(result.name).toBe("Label");
    });

    test("ariaLabelBeatsAlt", () => {
      const result = compute(`
        <img src="a.jpg" aria-label="Label" alt="Alt"/>
      `);
      expect(result.name).toBe("Label");
    });

    test("labelledbyTargetWithAriaLabelContributesItsLabel", () => {
      const result = compute(`
        <span id="l1" aria-label="Star">ignore me</span>
        <img src="a.jpg" aria-labelledby="l1"/>
      `);
      expect(result.name).toBe("Star");
    });

    test("labelledbyReferencedTextIsWhitespaceNormalized", () => {
      const result = compute(`
        <p id="l1">Hello
            beautiful   world</p>
        <img src="a.jpg" aria-labelledby="l1"/>
      `);
      expect(result.name).toBe("Hello beautiful world");
    });

    test("decorativeAltBlocksTitleAsName", () => {
      const result = compute(`
        <img src="a.jpg" alt="" title="Tooltip"/>
      `);
      expect(result.name).toBeNull();
      expect(result.description).toBe("Tooltip");
    });

    test("decorativeAltWithAriaLabelStillGetsAName", () => {
      const result = compute(`
        <img src="a.jpg" alt="" aria-label="Label"/>
      `);
      expect(result.name).toBe("Label");
    });

    test("titleFallbackIsConsumedByTheName", () => {
      const result = compute(`
        <img src="a.jpg" title="Tooltip"/>
      `);
      expect(result.name).toBe("Tooltip");
      expect(result.description).toBeNull();
    });
  });

  describe("accessible description", () => {
    test("ariaDescribedbyProvidesTheDescription", () => {
      const result = compute(`
        <p id="d1">Long description.</p>
        <img src="a.jpg" alt="Alt" aria-describedby="d1"/>
      `);
      expect(result.name).toBe("Alt");
      expect(result.description).toBe("Long description.");
    });

    test("ariaDescriptionProvidesTheDescription", () => {
      const result = compute(`
        <img src="a.jpg" alt="Alt" aria-description="Long description."/>
      `);
      expect(result.name).toBe("Alt");
      expect(result.description).toBe("Long description.");
    });

    test("describedbyWithDanglingIDsStillStopsTheDescriptionCascade", () => {
      const result = compute(`
        <img src="a.jpg" alt="Alt" aria-describedby="missing" title="Tooltip"/>
      `);
      expect(result.description).toBeNull();
    });
  });

  describe("suppression", () => {
    test("ariaHiddenSuppressesNameAndDescription", () => {
      const result = compute(`
        <img src="a.jpg" alt="Alt" aria-hidden="true" title="Tooltip"/>
      `);
      expect(result.name).toBeNull();
      expect(result.description).toBeNull();
    });

    test("presentationalRoleSuppressesNameAndDescription", () => {
      const result = compute(`
        <img src="a.jpg" alt="Alt" role="presentation"/>
      `);
      expect(result.name).toBeNull();
      expect(result.description).toBeNull();
    });

    test("globalARIAAttributeCancelsPresentationalRole", () => {
      const result = compute(`
        <img src="a.jpg" role="presentation" aria-label="Label"/>
      `);
      expect(result.name).toBe("Label");
    });

    test("ariaDescribedbyCancelsPresentationalRole", () => {
      const result = compute(`
        <p id="d1">D</p>
        <img src="a.jpg" alt="Alt" role="presentation" aria-describedby="d1"/>
      `);
      expect(result.name).toBe("Alt");
      expect(result.description).toBe("D");
    });

    test("ariaHiddenComparisonIsCaseInsensitive", () => {
      const result = compute(`
        <img src="a.jpg" alt="Alt" aria-hidden="TRUE"/>
      `);
      expect(result.name).toBeNull();
    });

    test("roleComparisonIsCaseInsensitive", () => {
      const result = compute(`
        <img src="a.jpg" alt="Alt" role="Presentation"/>
      `);
      expect(result.name).toBeNull();
    });
  });

  describe("SVG host-language sources", () => {
    test("svgTitleProvidesTheName", () => {
      const result = compute(`
        <svg><title>Chart title</title><circle/></svg>
      `);
      expect(result.name).toBe("Chart title");
    });

    test("svgDescProvidesTheDescription", () => {
      const result = compute(`
        <svg><title>Chart title</title><desc>Chart description</desc><circle/></svg>
      `);
      expect(result.description).toBe("Chart description");
    });
  });

  describe("figcaption as name (HTML-AAM 4.1.10 step 4)", () => {
    test("figcaptionNamesAnImageWithNoOtherNameSource", () => {
      document.body.innerHTML = `
        <figure><img src="a.jpg"/><figcaption>Cap</figcaption></figure>
      `;
      const element = document.body.querySelector("img")!;
      const result = computeAccessibilityProperties(element);
      expect(result.name).toBe("Cap");
      expect(findFigureCaption(element)).toBe("Cap");
    });

    test("figcaptionAsNameBlockedByOtherFlowContent", () => {
      document.body.innerHTML = `
        <figure><img src="a.jpg"/><p>Extra prose</p><figcaption>Cap</figcaption></figure>
      `;
      const element = document.body.querySelector("img")!;
      const result = computeAccessibilityProperties(element);
      expect(result.name).toBeNull();
      expect(findFigureCaption(element)).toBe("Cap");
    });

    test("figcaptionAsNameBlockedByASecondImage", () => {
      const result = compute(`
        <figure><img src="a.jpg"/><img src="b.jpg" alt="B"/><figcaption>Cap</figcaption></figure>
      `);
      expect(result.name).toBeNull();
    });

    test("figcaptionAsNameBlockedByAltAttribute", () => {
      const result = compute(`
        <figure><img src="a.jpg" alt=""/><figcaption>Cap</figcaption></figure>
      `);
      expect(result.name).toBeNull();
    });
  });
});

describe("findFigureCaption", () => {
  test("imageInFigureGetsCaptionFromFigcaption", () => {
    document.body.innerHTML = `
      <figure><img src="a.jpg" alt="Alt text"/><figcaption>The caption</figcaption></figure>
    `;
    const element = document.body.querySelector("img")!;
    expect(findFigureCaption(element)).toBe("The caption");
  });

  test("nestedFigureUsesTheNearestFigcaption", () => {
    document.body.innerHTML = `
      <figure>
        <figure><img src="a.jpg" alt="Alt"/><figcaption>Inner</figcaption></figure>
        <figcaption>Outer</figcaption>
      </figure>
    `;
    const element = document.body.querySelector("img")!;
    expect(findFigureCaption(element)).toBe("Inner");
  });

  test("figcaptionNotFirstChildStillProvidesTheCaption", () => {
    document.body.innerHTML = `
      <figure><p>intro</p><img src="a.jpg" alt="Alt"/><figcaption>Cap</figcaption></figure>
    `;
    const element = document.body.querySelector("img")!;
    expect(findFigureCaption(element)).toBe("Cap");
  });

  test("elementOutsideAFigureHasNoCaption", () => {
    document.body.innerHTML = `<img src="a.jpg" alt="Alt"/>`;
    const element = document.body.querySelector("img")!;
    expect(findFigureCaption(element)).toBeNull();
  });
});
