//
//  Copyright 2026 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import CoreGraphics
@testable import ReadiumNavigator
import Testing

struct PDFDecorationTemplateTests {
    struct LayoutRects {
        // Two line boxes in PDF user space; their union is (5, 85, 80, 25).
        let lineRects = [
            CGRect(x: 10, y: 100, width: 50, height: 10),
            CGRect(x: 5, y: 85, width: 80, height: 10),
        ]
        let pageBounds = CGRect(x: 0, y: 0, width: 432, height: 648)

        @Test func boxesWrapKeepsLineBoxes() {
            let rects = makeTemplate(layout: .boxes, width: .wrap).layoutRects(for: lineRects, pageBounds: pageBounds)
            #expect(rects == lineRects)
        }

        @Test func boundsIsTheUnionOfLineBoxes() {
            let rects = makeTemplate(layout: .bounds, width: .wrap).layoutRects(for: lineRects, pageBounds: pageBounds)
            #expect(rects == [CGRect(x: 5, y: 85, width: 80, height: 25)])
        }

        @Test func boundsWidthStretchesEachBoxToTheBoundingBox() {
            let rects = makeTemplate(layout: .boxes, width: .bounds).layoutRects(for: lineRects, pageBounds: pageBounds)
            #expect(rects == [
                CGRect(x: 5, y: 100, width: 80, height: 10),
                CGRect(x: 5, y: 85, width: 80, height: 10),
            ])
        }

        @Test func pageWidthStretchesEachBoxToThePage() {
            let rects = makeTemplate(layout: .boxes, width: .page).layoutRects(for: lineRects, pageBounds: pageBounds)
            #expect(rects == [
                CGRect(x: 0, y: 100, width: 432, height: 10),
                CGRect(x: 0, y: 85, width: 432, height: 10),
            ])
        }

        @Test func boundsLayoutWithPageWidth() {
            let rects = makeTemplate(layout: .bounds, width: .page).layoutRects(for: lineRects, pageBounds: pageBounds)
            #expect(rects == [CGRect(x: 0, y: 85, width: 432, height: 25)])
        }

        @Test func pageWidthAccountsForCropBoxOrigin() {
            let bounds = CGRect(x: 90, y: 72, width: 300, height: 500)
            let rects = makeTemplate(layout: .bounds, width: .page).layoutRects(for: lineRects, pageBounds: bounds)
            #expect(rects == [CGRect(x: 90, y: 85, width: 300, height: 25)])
        }

        @Test func singleRectPassesThrough() {
            let rect = CGRect(x: 10, y: 20, width: 100, height: 50)
            let rects = makeTemplate(layout: .boxes, width: .wrap).layoutRects(for: [rect], pageBounds: pageBounds)
            #expect(rects == [rect])
        }

        @Test func emptyInputYieldsNoRects() {
            let rects = makeTemplate(layout: .boxes, width: .wrap).layoutRects(for: [], pageBounds: pageBounds)
            #expect(rects.isEmpty)
        }
    }

    struct PageSpaceConversion {
        @Test func flipsToTopLeftOrigin() {
            let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
                .convertedFromPDFSpace(pageBounds: CGRect(x: 0, y: 0, width: 432, height: 648))
            #expect(rect == CGRect(x: 10, y: 588, width: 30, height: 40))
        }

        @Test func accountsForCropBoxOrigin() {
            let rect = CGRect(x: 100, y: 100, width: 50, height: 20)
                .convertedFromPDFSpace(pageBounds: CGRect(x: 90, y: 72, width: 300, height: 500))
            #expect(rect == CGRect(x: 10, y: 452, width: 50, height: 20))
        }
    }
}

// MARK: - Helpers

private func makeTemplate(layout: PDFDecorationTemplate.Layout, width: PDFDecorationTemplate.Width) -> PDFDecorationTemplate {
    PDFDecorationTemplate(layout: layout, width: width, renderer: .draw { _, _, _ in })
}
