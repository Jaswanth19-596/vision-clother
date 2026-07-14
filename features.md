2. Wishlist Simulation Mode ("Try Before You Buy")
Concept: Allow users to snap a photo of a clothing item in a store or import an image from a website, marking it as a "Wishlist Item" to see how many high-scoring outfit combinations it unlocks with their existing wardrobe before purchasing it.
Why it's useful: Prevents buyer's remorse by proving compatibility with their current closet beforehand.
Where to implement:
Add a isWishlistItem boolean to 

WardrobeItem
.
Exclude wishlist items from 

DailyAssistantView
 recommendations, but allow testing them in 

ManualPairingView
.