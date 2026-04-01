import Foundation
import ShuttleKit

struct ShuttleCheckoutPresentation {
    let shortLabel: String
    let detail: String?
}

func shuttleCheckoutPresentation(
    for _: SessionProject,
    sessionRootPath _: String
) -> ShuttleCheckoutPresentation {
    ShuttleCheckoutPresentation(
        shortLabel: "Direct Source",
        detail: "Uses the source directory directly. New tabs open here by default."
    )
}
