import Foundation
import CoreGraphics

let destination = URL(fileURLWithPath: CommandLine.arguments[1])
var bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
let consumer = CGDataConsumer(url: destination as CFURL)!
let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
context.beginPDFPage(nil)
context.translateBy(x: 0, y: 32)
context.scaleBy(x: 1, y: -1)
context.setStrokeColor(CGColor(gray: 0, alpha: 1))
context.setLineWidth(2.4)
context.setLineCap(.round)
context.setLineJoin(.round)
for (start, end, y) in [(5.0, 27.0, 6.0), (8.0, 24.0, 12.0), (11.0, 21.0, 18.0)] {
    context.move(to: CGPoint(x: start, y: y))
    context.addLine(to: CGPoint(x: end, y: y))
}
context.move(to: CGPoint(x: 16, y: 19))
context.addLine(to: CGPoint(x: 16, y: 27))
context.move(to: CGPoint(x: 12, y: 23))
context.addLine(to: CGPoint(x: 16, y: 27))
context.addLine(to: CGPoint(x: 20, y: 23))
context.strokePath()
context.endPDFPage()
context.closePDF()
