// Search and filters for SwipeClean on Android, matching the iPhone version:
// - photo types: favourites, camera photos, screenshots and panoramas,
// - months and years ("march", "2023", "märz 2021"),
// - places: each photo's location (from its EXIF data) turned into a place name and saved,
// - things and text in photos, recognised on the phone with Google's ML Kit.

package com.example.swipeclean

import android.content.Context
import android.location.Geocoder
import android.net.Uri
import android.provider.MediaStore
import android.util.Size
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Clear
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SuggestionChip
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.exifinterface.media.ExifInterface
import coil.compose.AsyncImage
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.label.ImageLabeler
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.text.Normalizer
import java.time.format.TextStyle
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToLong

/** Lowercased and without accents, for matching ("Köln" -> "koln", "Straße" -> "strasse"). */
fun String.folded(): String =
    Normalizer.normalize(lowercase(Locale.ROOT).replace("ß", "ss"), Normalizer.Form.NFD)
        .replace(Regex("\\p{Mn}+"), "")

// ---------------------------------------------------------------- Filters

enum class PhotoFilter(val title: String, private val words: List<String>) {
    FAVORITES("Favourites", listOf("favourites", "favorites", "favourite", "favorite", "favoriten", "favorit")),
    CAMERA("Camera", listOf("camera", "kamera")),
    SCREENSHOTS("Screenshots", listOf("screenshots", "screenshot", "bildschirmfotos", "bildschirmfoto")),
    PANORAMAS("Panoramas", listOf("panoramas", "panorama", "pano"));

    fun matchesWord(token: String): Boolean = token.length >= 3 && words.any { it.startsWith(token) }
}

fun PhotoStore.has(filter: PhotoFilter, photo: Photo): Boolean {
    val path = pathOf(photo)
    return when (filter) {
        PhotoFilter.FAVORITES -> isFavorite(photo)
        PhotoFilter.CAMERA -> path.startsWith("DCIM/Camera", ignoreCase = true)
        PhotoFilter.SCREENSHOTS -> isScreenshotPath(path)
        PhotoFilter.PANORAMAS -> {
            // Android has no panorama flag, so: very wide (or tall) photos that aren't screenshots.
            val long = max(photo.width, photo.height)
            val short = min(photo.width, photo.height)
            short > 0 && long.toFloat() / short >= 2.5f && !isScreenshotPath(path)
        }
    }
}

private fun isScreenshotPath(path: String) = path.contains("screenshot", ignoreCase = true)

// ---------------------------------------------------------------- Query

data class SearchQuery(val text: String = "", val filters: Set<PhotoFilter> = emptySet()) {
    val tokens: List<String>
        get() = text.folded().split(Regex("[\\s,]+")).filter { it.isNotEmpty() && it !in FILLERS }

    val isEmpty: Boolean get() = tokens.isEmpty() && filters.isEmpty()

    val title: String
        get() = (listOf(text.trim()).filter { it.isNotEmpty() } +
            PhotoFilter.entries.filter { it in filters }.map { it.title }).joinToString(" · ")

    companion object {
        /** Words that don't narrow anything down ("photos from berlin" = "berlin"). */
        private val FILLERS = setOf(
            "photo", "photos", "foto", "fotos", "picture", "pictures", "pic", "pics", "bild", "bilder",
            "from", "in", "at", "of", "the", "von", "aus", "im", "am", "der", "die", "das",
        )
    }
}

/** What a swipe deck goes through: one month, or the results of a search. */
sealed interface DeckSource {
    data class MonthDeck(val key: Int) : DeckSource
    data class SearchDeck(val query: SearchQuery) : DeckSource
}

/** Month names in the phone's language, English and German, folded ("märz" -> 3). */
private val monthNumbers: Map<String, Int> by lazy {
    val map = HashMap<String, Int>()
    val styles = listOf(TextStyle.FULL, TextStyle.SHORT, TextStyle.FULL_STANDALONE, TextStyle.SHORT_STANDALONE)
    for (locale in listOf(Locale.getDefault(), Locale.ENGLISH, Locale.GERMAN)) {
        for (month in java.time.Month.values()) {
            for (style in styles) {
                map[month.getDisplayName(style, locale).folded().replace(".", "")] = month.value
            }
        }
    }
    map
}

/** One typed word, and everything it could mean. */
private class SearchTerm(token: String, places: PlaceIndex, content: ContentIndex) {
    val year: Int? = token.takeIf { it.length == 4 }?.toIntOrNull()?.takeIf { it in 1900..2100 }
    val month: Int? = monthNumbers[token]
    val filters: List<PhotoFilter> = PhotoFilter.entries.filter { it.matchesWord(token) }
    val squares: Set<String> = places.squares(matching = token)
    val photos: Set<Long> = content.photos(matching = token)
}

/**
 * Every photo that fits the query, newest first. Each typed word has to fit (as a year, a month,
 * a photo type, a place, or something in the photo), and so does every chosen filter.
 */
fun PhotoStore.search(query: SearchQuery, places: PlaceIndex, content: ContentIndex): List<Photo> {
    val terms = query.tokens.map { SearchTerm(it, places, content) }
    val results = ArrayList<Photo>()
    for (month in months) {
        val year = month.key / 100
        val monthNumber = month.key % 100
        for (photo in month.photos) {
            if (!query.filters.all { has(it, photo) }) continue
            val square = places.squareOf(photo.id)
            val fits = terms.all { term ->
                term.year == year ||
                    term.month == monthNumber ||
                    term.filters.any { has(it, photo) } ||
                    (square != null && square in term.squares) ||
                    photo.id in term.photos
            }
            if (fits) results.add(photo)
        }
    }
    return results
}

fun PhotoStore.photosFor(source: DeckSource, places: PlaceIndex, content: ContentIndex): List<Photo> =
    when (source) {
        is DeckSource.MonthDeck -> month(source.key)?.photos ?: emptyList()
        is DeckSource.SearchDeck -> search(source.query, places, content)
    }

fun PhotoStore.unreviewed(source: DeckSource, places: PlaceIndex, content: ContentIndex): List<Photo> =
    photosFor(source, places, content).filter { it.id !in kept && it.id !in trashIds }

/** Lets you go through these photos again. Photos already marked for deletion stay marked. */
fun PhotoStore.reviewAgain(source: DeckSource, places: PlaceIndex, content: ContentIndex) {
    unkeep(photosFor(source, places, content).map { it.id }.toSet())
}

fun PhotoStore.title(source: DeckSource): String = when (source) {
    is DeckSource.MonthDeck -> month(source.key)?.title ?: "SwipeClean"
    is DeckSource.SearchDeck -> source.query.title
}

private fun JSONObject.str(key: String): String? = if (has(key) && !isNull(key)) getString(key) else null

// ---------------------------------------------------------------- Places

data class Place(
    val name: String?,
    val street: String?,
    val district: String?,
    val city: String?,
    val area: String?,
    val country: String?,
) {
    /** The name shown on a chip: the city if there is one. */
    val label: String? get() = city ?: district ?: area ?: country
    val names: Set<String> get() = listOfNotNull(city, district, street, area, country).toSet()
    val searchText: String get() = listOfNotNull(name, street, district, city, area, country).joinToString(" ").folded()

    fun toJson(): JSONObject = JSONObject().apply {
        put("name", name); put("street", street); put("district", district)
        put("city", city); put("area", area); put("country", country)
    }

    companion object {
        fun fromJson(o: JSONObject) =
            Place(o.str("name"), o.str("street"), o.str("district"), o.str("city"), o.str("area"), o.str("country"))
    }
}

/**
 * Turns photo locations into place names and remembers them. Locations are read from each photo's
 * EXIF data (Android needs the "media location" permission for that). Photos are grouped into small
 * map squares (a few hundred metres across), and each square is looked up once, busiest first.
 * Progress is saved as it goes and carries on at the next launch.
 */
class PlaceIndex(private val context: Context) {
    /** What's happening right now, or null when done. */
    var status by mutableStateOf<String?>(null)
        private set
    var revision by mutableIntStateOf(0)   // bumps as places are found
        private set

    private val places = HashMap<String, Place>()       // square -> place
    private val texts = HashMap<String, String>()       // square -> folded text to search
    private val coords = HashMap<Long, DoubleArray?>()  // photo id -> lat/lon (null = none)
    private val squareOf = HashMap<Long, String>()
    private val photosPerSquare = HashMap<String, Int>()
    private var cacheLoaded = false

    private val placesFile get() = File(context.filesDir, "places.json")
    private val coordsFile get() = File(context.filesDir, "coords.json")

    val isWorking: Boolean get() = status != null

    suspend fun run(months: List<Month>, canReadLocation: Boolean) {
        if (!cacheLoaded) loadCaches()
        if (!canReadLocation) return
        val photos = months.flatMap { it.photos }

        // 1. Read the location of photos we haven't seen yet.
        val missing = photos.filter { !coords.containsKey(it.id) }
        try {
            for ((i, batch) in missing.chunked(100).withIndex()) {
                status = "Reading photo locations… ${i * 100} of ${missing.size}"
                val found = withContext(Dispatchers.IO) { batch.map { it.id to readLocation(it.uri) } }
                for ((id, latLon) in found) coords[id] = latLon
                if (i % 10 == 9) saveCoords()
            }
        } finally {
            saveCoords()
        }

        // 2. Group photos into squares.
        squareOf.clear()
        photosPerSquare.clear()
        val spots = HashMap<String, DoubleArray>()
        for (photo in photos) {
            val latLon = coords[photo.id] ?: continue
            val square = square(latLon)
            squareOf[photo.id] = square
            photosPerSquare[square] = (photosPerSquare[square] ?: 0) + 1
            spots.putIfAbsent(square, latLon)
        }
        revision++

        // 3. Look up each square's place name, busiest first.
        if (!Geocoder.isPresent()) {
            status = null
            return
        }
        val pending = photosPerSquare.keys.filter { it !in places }.sortedByDescending { photosPerSquare[it] }
        val geocoder = Geocoder(context, Locale.getDefault())
        var failures = 0
        var found = 0
        try {
            for (square in pending) {
                status = "Finding places… ${photosPerSquare.size - pending.size + found} of ${photosPerSquare.size}"
                val latLon = spots[square] ?: continue
                val result = withContext(Dispatchers.IO) {
                    runCatching {
                        @Suppress("DEPRECATION")
                        geocoder.getFromLocation(latLon[0], latLon[1], 1)
                    }
                }
                if (result.isFailure) {
                    // Offline, or asked to slow down: wait, then carry on (or stop until next launch).
                    if (++failures >= 3) break
                    delay(30_000)
                    continue
                }
                failures = 0
                val address = result.getOrNull()?.firstOrNull()
                val place = Place(
                    address?.featureName, address?.thoroughfare, address?.subLocality,
                    address?.locality, address?.adminArea, address?.countryName,
                )
                places[square] = place
                texts[square] = place.searchText
                found++
                revision++
                if (found % 25 == 0) savePlaces()
                delay(300)
            }
        } finally {
            savePlaces()
            status = null
        }
    }

    fun squareOf(photoId: Long): String? = squareOf[photoId]

    fun squares(matching: String): Set<String> =
        texts.filterValues { it.contains(matching) }.keys

    /** The places with the most photos, for the chips. */
    fun topPlaces(limit: Int): List<String> {
        val counts = HashMap<String, Int>()
        for ((square, count) in photosPerSquare) {
            val label = places[square]?.label ?: continue
            counts[label] = (counts[label] ?: 0) + count
        }
        return counts.entries.sortedByDescending { it.value }.take(limit).map { it.key }
    }

    /** Place names containing what's typed, most photos first. */
    fun suggestions(typed: String, limit: Int = 5): List<String> {
        val counts = HashMap<String, Int>()
        for ((square, count) in photosPerSquare) {
            val place = places[square] ?: continue
            for (name in place.names) {
                if (name.folded().contains(typed)) counts[name] = (counts[name] ?: 0) + count
            }
        }
        return counts.entries.sortedByDescending { it.value }.take(limit).map { it.key }
    }

    private fun square(latLon: DoubleArray): String {
        val size = 0.003   // degrees, roughly 300 m north–south
        return "${(latLon[0] / size).roundToLong()}:${(latLon[1] / size).roundToLong()}"
    }

    private fun readLocation(uri: Uri): DoubleArray? = runCatching {
        context.contentResolver.openInputStream(MediaStore.setRequireOriginal(uri))?.use { stream ->
            ExifInterface(stream).latLong?.takeIf { !(it[0] == 0.0 && it[1] == 0.0) }
        }
    }.getOrNull()

    // Saving

    private suspend fun loadCaches() {
        cacheLoaded = true
        val (savedPlaces, savedCoords) = withContext(Dispatchers.IO) {
            val p = HashMap<String, Place>()
            runCatching {
                val o = JSONObject(placesFile.readText())
                for (key in o.keys()) p[key] = Place.fromJson(o.getJSONObject(key))
            }
            val c = HashMap<Long, DoubleArray?>()
            runCatching {
                val o = JSONObject(coordsFile.readText())
                for (key in o.keys()) {
                    val id = key.toLongOrNull() ?: continue
                    val a = o.optJSONArray(key)
                    c[id] = if (a == null) null else doubleArrayOf(a.getDouble(0), a.getDouble(1))
                }
            }
            p to c
        }
        places.putAll(savedPlaces)
        for ((square, place) in savedPlaces) texts[square] = place.searchText
        coords.putAll(savedCoords)
    }

    private suspend fun savePlaces() {
        val json = JSONObject().apply { for ((k, v) in places) put(k, v.toJson()) }.toString()
        withContext(NonCancellable + Dispatchers.IO) { runCatching { placesFile.writeText(json) } }
    }

    private suspend fun saveCoords() {
        val json = JSONObject().apply {
            for ((k, v) in coords) put(k.toString(), if (v == null) JSONObject.NULL else JSONArray().put(v[0]).put(v[1]))
        }.toString()
        withContext(NonCancellable + Dispatchers.IO) { runCatching { coordsFile.writeText(json) } }
    }
}

// ---------------------------------------------------------------- Things and text (ML Kit)

/**
 * What's in each photo, found on the phone with ML Kit: things and scenes ("dog", "beach", "food")
 * for every photo, and text for screenshots and photos that look like documents or signs.
 * Nothing leaves the phone. Results are saved, so each photo is only looked at once.
 */
class ContentIndex(private val context: Context) {
    var done by mutableIntStateOf(0)
        private set
    var total by mutableIntStateOf(0)
        private set
    var revision by mutableIntStateOf(0)
        private set

    private val labels = HashMap<Long, List<String>>()       // photo id -> labels
    private val byLabel = HashMap<String, MutableSet<Long>>()
    private val texts = HashMap<Long, String>()              // photo id -> folded text
    private var cacheLoaded = false

    private val file get() = File(context.filesDir, "content.json")

    val isWorking: Boolean get() = done < total

    suspend fun run(months: List<Month>, isScreenshot: (Photo) -> Boolean) {
        if (!cacheLoaded) loadCache()
        val photos = months.flatMap { it.photos }
        val pending = photos.filter { it.id !in labels }
        total = photos.size
        done = photos.size - pending.size
        if (pending.isEmpty()) return

        val labeler = ImageLabeling.getClient(
            ImageLabelerOptions.Builder().setConfidenceThreshold(0.6f).build()
        )
        val reader = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        var unsaved = 0
        try {
            for (batch in pending.chunked(20)) {
                val work = batch.map { it to isScreenshot(it) }
                val results = withContext(Dispatchers.Default) {
                    work.map { (photo, screenshot) -> photo.id to analyse(photo, screenshot, labeler, reader) }
                }
                for ((id, result) in results) {
                    if (result != null) {
                        add(id, result.first, result.second)
                        unsaved++
                    }
                }
                done += batch.size
                revision++
                if (unsaved >= 200) {
                    save()
                    unsaved = 0
                }
            }
        } finally {
            labeler.close()
            reader.close()
            save()
        }
    }

    /** Photos showing something whose name starts with the word, or with the word in their text. */
    fun photos(matching: String): Set<Long> {
        if (matching.length < 3) return emptySet()
        val ids = HashSet<Long>()
        val translated = ContentWords.labels(matching)
        for ((label, labelIds) in byLabel) {
            if (label in translated || startsWith(label, matching)) ids.addAll(labelIds)
        }
        for ((id, text) in texts) if (text.contains(matching)) ids.add(id)
        return ids
    }

    /** Things that match what's typed, most photos first. */
    fun suggestions(typed: String, limit: Int = 4): List<String> {
        if (typed.length < 3) return emptyList()
        val translated = ContentWords.labels(typed)
        return byLabel.entries
            .filter { it.key in translated || startsWith(it.key, typed) }
            .sortedByDescending { it.value.size }
            .take(limit)
            .map { it.key }
    }

    private fun startsWith(label: String, token: String) =
        label.split(' ', '_').any { it.startsWith(token) }

    private fun add(id: Long, names: List<String>, text: String?) {
        labels[id] = names
        for (name in names) byLabel.getOrPut(name) { HashSet() }.add(id)
        if (text != null) texts[id] = text
    }

    /** Runs off the main thread. Null if the photo couldn't be loaded. */
    private fun analyse(
        photo: Photo,
        screenshot: Boolean,
        labeler: ImageLabeler,
        reader: TextRecognizer,
    ): Pair<List<String>, String?>? {
        val small = runCatching {
            context.contentResolver.loadThumbnail(photo.uri, Size(360, 360), null)
        }.getOrNull() ?: return null
        val found = runCatching { Tasks.await(labeler.process(InputImage.fromBitmap(small, 0))) }
            .getOrNull() ?: return null
        val names = found.map { it.text.folded() }

        var text: String? = null
        if (screenshot || names.any { it in TEXT_LABELS }) {
            val large = runCatching {
                context.contentResolver.loadThumbnail(photo.uri, Size(1400, 1400), null)
            }.getOrNull()
            if (large != null) {
                text = runCatching { Tasks.await(reader.process(InputImage.fromBitmap(large, 0))).text }
                    .getOrNull()
                    ?.folded()
                    ?.take(2000)
                    ?.takeIf { it.isNotBlank() }
            }
        }
        return names to text
    }

    private suspend fun loadCache() {
        cacheLoaded = true
        val saved = withContext(Dispatchers.IO) {
            val out = ArrayList<Triple<Long, List<String>, String?>>()
            runCatching {
                val o = JSONObject(file.readText())
                for (key in o.keys()) {
                    val id = key.toLongOrNull() ?: continue
                    val entry = o.getJSONObject(key)
                    val l = entry.getJSONArray("l")
                    out.add(Triple(id, List(l.length()) { l.getString(it) }, entry.str("t")))
                }
            }
            out
        }
        for ((id, names, text) in saved) add(id, names, text)
    }

    private suspend fun save() {
        val json = JSONObject().apply {
            for ((id, names) in labels) {
                put(id.toString(), JSONObject().apply {
                    put("l", JSONArray(names))
                    texts[id]?.let { put("t", it) }
                })
            }
        }.toString()
        withContext(NonCancellable + Dispatchers.IO) { runCatching { file.writeText(json) } }
    }

    companion object {
        /** Labels that suggest there's text worth reading. */
        private val TEXT_LABELS = setOf(
            "paper", "poster", "menu", "receipt", "document", "text", "sign", "whiteboard",
            "newspaper", "book", "screenshot", "letter", "ticket", "handwriting", "comics", "publication",
        )
    }
}

/** German words for common things, mapped to ML Kit's English names. */
object ContentWords {
    private val german = mapOf(
        "hund" to listOf("dog"), "hunde" to listOf("dog"), "katze" to listOf("cat"), "katzen" to listOf("cat"),
        "pferd" to listOf("horse"), "vogel" to listOf("bird"), "tier" to listOf("animal", "pet"), "fisch" to listOf("fish"),
        "strand" to listOf("beach"), "meer" to listOf("sea", "ocean"), "see" to listOf("lake"),
        "berg" to listOf("mountain"), "berge" to listOf("mountain"), "wald" to listOf("forest"),
        "baum" to listOf("tree"), "baume" to listOf("tree"), "blume" to listOf("flower"), "blumen" to listOf("flower"),
        "himmel" to listOf("sky"), "wolke" to listOf("cloud"), "wolken" to listOf("cloud"), "schnee" to listOf("snow"),
        "sonnenuntergang" to listOf("sunset"), "sonnenaufgang" to listOf("sunset"), "nacht" to listOf("night"),
        "essen" to listOf("food"), "kuchen" to listOf("cake"), "torte" to listOf("cake"), "brot" to listOf("bread"),
        "obst" to listOf("fruit"), "gemuse" to listOf("vegetable"), "getrank" to listOf("drink"),
        "kaffee" to listOf("coffee"), "bier" to listOf("beer"), "wein" to listOf("wine"),
        "auto" to listOf("car"), "fahrrad" to listOf("bicycle"), "motorrad" to listOf("motorcycle"),
        "flugzeug" to listOf("airplane"), "zug" to listOf("train"), "boot" to listOf("boat"), "schiff" to listOf("ship", "boat"),
        "haus" to listOf("house", "building"), "gebaude" to listOf("building"), "kirche" to listOf("church"),
        "brucke" to listOf("bridge"), "stadt" to listOf("city"), "strasse" to listOf("road", "street"),
        "menschen" to listOf("people", "crowd"), "leute" to listOf("people", "crowd"), "kind" to listOf("child"),
        "kinder" to listOf("child"), "konzert" to listOf("concert"), "party" to listOf("party"),
        "geburtstag" to listOf("birthday"), "hochzeit" to listOf("wedding"), "feuerwerk" to listOf("fireworks"),
        "weihnachten" to listOf("christmas"), "dokument" to listOf("document", "paper"), "quittung" to listOf("receipt"),
        "rechnung" to listOf("receipt", "paper"), "buch" to listOf("book"), "spielzeug" to listOf("toy"),
        "handy" to listOf("mobile phone"), "tisch" to listOf("table"), "fenster" to listOf("window"),
        "garten" to listOf("garden"), "wasser" to listOf("water"), "schwimmbad" to listOf("swimming pool", "pool"),
        "kleidung" to listOf("clothing"), "schuhe" to listOf("shoe"), "bett" to listOf("bed"), "kuche" to listOf("kitchen"),
    )

    /** ML Kit names for a German word (or the start of one). */
    fun labels(token: String): Set<String> =
        if (token.length < 3) emptySet()
        else german.filterKeys { it.startsWith(token) }.values.flatten().toSet()
}

// ---------------------------------------------------------------- Views

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchHeader(
    query: SearchQuery,
    onQuery: (SearchQuery) -> Unit,
    places: PlaceIndex,
    content: ContentIndex,
) {
    val typed = query.text.folded().trim()
    val suggestions = remember(typed, places.revision, content.revision) {
        if (typed.length < 2) emptyList()
        else (PhotoFilter.entries.filter { it.matchesWord(typed) }.map { it.title } +
            content.suggestions(typed).map { it.replaceFirstChar { c -> c.uppercase() } } +
            places.suggestions(typed)).distinctBy { it.folded() }.take(8)
    }
    val showSuggestions = suggestions.isNotEmpty() && suggestions.none { it.folded() == typed }
    val topPlaces = remember(places.revision) { places.topPlaces(8) }

    Column {
        OutlinedTextField(
            value = query.text,
            onValueChange = { onQuery(query.copy(text = it)) },
            placeholder = { Text("Places, things, text, months…") },
            leadingIcon = { Icon(Icons.Filled.Search, contentDescription = null) },
            trailingIcon = {
                if (query.text.isNotEmpty()) {
                    IconButton(onClick = { onQuery(query.copy(text = "")) }) {
                        Icon(Icons.Filled.Clear, contentDescription = "Clear")
                    }
                }
            },
            singleLine = true,
            shape = RoundedCornerShape(50),
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp),
        )
        LazyRow(
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            if (showSuggestions) {
                items(suggestions) { suggestion ->
                    SuggestionChip(
                        onClick = { onQuery(query.copy(text = suggestion)) },
                        label = { Text(suggestion) },
                    )
                }
            } else {
                items(PhotoFilter.entries) { filter ->
                    FilterChip(
                        selected = filter in query.filters,
                        onClick = {
                            val filters = if (filter in query.filters) query.filters - filter else query.filters + filter
                            onQuery(query.copy(filters = filters))
                        },
                        label = { Text(filter.title) },
                    )
                }
                items(topPlaces) { place ->
                    val on = typed == place.folded()
                    FilterChip(
                        selected = on,
                        onClick = { onQuery(query.copy(text = if (on) "" else place)) },
                        label = { Text(place) },
                        leadingIcon = { Icon(Icons.Filled.Place, contentDescription = null, modifier = Modifier.size(18.dp)) },
                    )
                }
            }
        }
    }
}

@Composable
fun SearchResults(
    store: PhotoStore,
    places: PlaceIndex,
    content: ContentIndex,
    query: SearchQuery,
    onOpen: (DeckSource) -> Unit,
    modifier: Modifier = Modifier,
) {
    val results = remember(query, places.revision, content.revision, store.months, store.favorites) {
        store.search(query, places, content)
    }
    val open = results.count { it.id !in store.kept && it.id !in store.trashIds }
    val scanning = content.isWorking || places.isWorking

    if (results.isEmpty()) {
        Box(modifier = modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
            Text(
                text = if (scanning) "No photos yet. Still scanning your photos, so more may turn up."
                else "No photos. Try a place, a month, a thing like \"dog\", or words in a screenshot.",
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        return
    }

    LazyVerticalGrid(
        columns = GridCells.Adaptive(90.dp),
        modifier = modifier.fillMaxSize(),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        item(span = { GridItemSpan(maxLineSpan) }) {
            Column(modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp)) {
                Text(
                    text = "${if (results.size == 1) "1 photo" else "${results.size} photos"} · $open not reviewed",
                    style = MaterialTheme.typography.titleSmall,
                )
                if (content.isWorking) {
                    Text(
                        "Scanning photos… ${content.done} of ${content.total}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                places.status?.let {
                    Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.height(8.dp))
                Button(
                    onClick = { onOpen(DeckSource.SearchDeck(query)) },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(if (open > 0) "Swipe through $open" else "All reviewed")
                }
            }
        }
        items(results, key = { it.id }) { photo ->
            val trashed = photo.id in store.trashIds
            val reviewed = trashed || photo.id in store.kept
            Box {
                AsyncImage(
                    model = photo.uri,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .aspectRatio(1f)
                        .alpha(if (reviewed) 0.45f else 1f),
                )
                if (reviewed) {
                    Icon(
                        if (trashed) Icons.Filled.Delete else Icons.Filled.CheckCircle,
                        contentDescription = if (trashed) "Marked for deletion" else "Kept",
                        tint = if (trashed) Color(0xFFD32F2F) else Color(0xFF2E7D32),
                        modifier = Modifier
                            .align(Alignment.BottomEnd)
                            .padding(4.dp)
                            .size(20.dp),
                    )
                }
            }
        }
    }
}
