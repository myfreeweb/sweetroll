'use strict'

// There's no strict rule about "what is a helper" but generally,
// helpers are about data manipulation.

import _ from 'lodash'
const { head, some, trim, get, eq, includes, concat, sortBy, capitalize,
	flatMap, isString, isArray, isObject, compact, difference } = _
import pug from 'pug'
import URI from 'urijs'
import debug from 'debug'
import gravatarUrl from 'gravatar-url'
import entities from 'entities'
import cheerio from 'cheerio'
import truncate from 'truncate-html'
import emoji from 'emoji-king'
const { count: countEmoji } = emoji
import remark from 'remark'
import remarkMath from 'remark-math'
import remarkKatex from 'remark-html-katex'
import remarkHl from 'remark-highlight.js'
import remarkHtml from 'remark-html'

const cacheTemplates = process.env.CACHE_TEMPLATES // Do not recompile templates on every request. Enable in prod for perf boost
const log = debug('sweetroll-fe:helpers')
const markdown = remark().use(remarkMath).use(remarkKatex).use(remarkHl).use(remarkHtml)

export function insertParams (name, params) {
	// TODO: make this more efficient
	let result = name
	for (const k of Object.keys(params)) {
		result = result.replace(`{${k}}`, params[k])
	}
	return result
}

export function matchingFeeds (feeds, obj) {
	return flatMap(feeds, feed => flatMap(feed.properties.filter, filter => {
		let matches = true
		const params = {}
		const walk = (x, y) => {
			for (const k of Object.keys(x)) {
				if (x[k].length === 1 && isString(x[k][0]) &&
					x[k][0].startsWith('{') && x[k][0].endsWith('}') && isArray(y[k])) {
					const p = trim(x[k][0], '{}')
					params[p] = concat(params[p] || [], y[k])
				} else if (isArray(x[k]) && isArray(y[k])) {
					matches = matches && difference(x[k], y[k]).length === 0
				} else if (isObject(x[k]) && isObject(y[k])) {
					walk(x[k], y[k])
				} else {
					matches = matches && eq(x[k], y[k])
				}
				if (!matches) return
			}
		}
		walk(filter, obj.properties)
		if (matches) {
			const base = new URI(feed.properties.url[0])
			if (Object.keys(params).length === 0) {
				return [{
					name: get(feed, 'properties.name[0]', ''),
					url: base.toString(),
					feedObj: feed,
					params: {}
				}]
			}
			return flatMap(Object.keys(params), k =>
				params[k].map(v => {
					const params = {[k]: v}
					return {
						name: this.insertParams(get(feed, 'properties.name[0]', ''), params),
						url: base.clone().search(params).toString(),
						feedObj: feed,
						params
					}
				}))
		}
	})).filter(isObject)
}

export function onlyHttpUrl (x) {
	if (!x) return 'javascript:void(0)'
	if (x.startsWith('/') || x.startsWith('http://') || x.startsWith('https://') || x.startsWith('//')) return x
	return 'javascript:void(0)'
}

export function isValidRef (url, x) {
	return some(x, v => some(url, u => v && ((v.startsWith && v.startsWith(u)) ||
		(v.value && v.value.startsWith && v.value.startsWith(u)))))
}

export function separateComments (url, comments) {
	const result = { replies: [], likes: [], reposts: [], bookmarks: [], quotations: [], mentions: [] }
	for (const comment of comments) {
		const properties = comment.properties || {}
		if (this.isValidRef(url, properties['in-reply-to'])) {
			const text = trim(get(properties, 'content[0].value', get(properties, 'name[0]', 'xxxxxxxxxx')))
			if (text.length < 16) {
				const emoji = countEmoji(text)
				if (emoji && Object.keys(emoji).length >= 1) {
					for (const e of Object.keys(emoji)) {
						result[e] = result[e] || []
						result[e].push(comment)
					}
					continue
				}
			}
			result.replies.push(comment)
		} else if (this.isValidRef(url, properties['like-of'])) {
			result.likes.push(comment)
		} else if (this.isValidRef(url, properties['repost-of'])) {
			result.reposts.push(comment)
		} else if (this.isValidRef(url, properties['bookmark-of'])) {
			result.bookmarks.push(comment)
		} else if (this.isValidRef(url, properties['quotation-of'])) {
			result.quotations.push(comment)
		} else {
			result.mentions.push(comment)
		}
	}
	return result
}

export function syndicationName (x) {
	if (includes(x, 'twitter.com')) return 'Twitter'
	if (includes(x, 'tumblr.com')) return 'Tumblr'
	if (includes(x, 'facebook.com')) return 'Facebook'
	if (includes(x, 'instagram.com')) return 'Instagram'
	const matches = x.match(/^https?:\/\/([^/?#]+)/)
	return (matches && matches[1]) || x
}

export function showAvatar (author) {
	return get(author, 'properties.photo[0]') ||
		gravatarUrl(
			get(author, 'properties.email[0]', 'test@example.com').replace('mailto:', ''),
			{ size: 256, default: 'identicon' }
		)
}

export function entryName (obj) {
	return get(obj, 'properties.name[0]') || get(obj, 'properties.published[0]', 'Untitled page')
}

export function ratingStars (rating, best) {
	if (rating > best) {
		return [best, 0, 0]
	}
	if (rating - Math.floor(rating) > 0.001) {
		return [Math.floor(rating), 1, best - Math.floor(rating) - 1]
	}
	return [Math.floor(rating), 0, best - Math.floor(rating)]
}

export function renderMarkdown (content) {
	return markdown.processSync(content).contents
}

export function getHtml (content) {
	if (isObject(content)) {
		if (isString(content.html)) {
			if (content.html.length > 1 && !content.html.includes('<p')) {
				return `<p>${content.html}</p>`
			}
			return content.html
		}
		if (isString(content.markdown || content.value)) {
			return this.renderMarkdown(content.markdown || content.value)
		}
	}
	if (isString(content)) {
		return this.renderMarkdown(content)
	}
}

export function getContent (properties, { preferSummary }) {
	const content = head(compact(
		preferSummary
			? concat(properties.summary || [], properties.content || [], properties.name || [])
			: concat(properties.content || [], properties.summary || [], properties.name || [])
	)) || ''
	return trim(this.getHtml(content))
}

export function processContent (properties, opts) {
	const textContent = this.getContent(properties, opts)
	const media = {
		photo: properties.photo || [],
		video: properties.video || [],
		audio: properties.audio || [],
	}
	if (!isString(textContent)) {
		log('non-string content from getContent to processContent')
		return Object.assign({ textContent }, media)
	}
	// NOTE: do not use => functions for cheerio!
	const $ = cheerio.load(textContent)
	// detwitterize emoji
	$('img.Emoji').each(function (i) {
		const img = $(this)
		img.replaceWith(`<span class="emoji">${img.attr('alt')}</span>`)
	})
	//$('img').each(function (i) { const img = $(this) })
	const helpers = this
	for (const mediaType of Object.keys(media)) {
		$(`${mediaType}-here`).each(function (i) {
			const el = $(this)
			let idx = media[mediaType].length
			while (idx--) {
				const obj = media[mediaType][idx]
				if (obj.id === el.attr('id')) {
					el.replaceWith($(pug.render(`include /_media.pug\n+show${capitalize(mediaType)}(media)`,
						{ media: obj, helpers, _, basedir: './views', cacheTemplates })))
					media[mediaType].splice(idx, 1)
				}
			}
		})
	}
	let txt = $('body').html()
	const isCrapName = this.isActuallyTheSameDamnThing(get(properties, 'name[0]') || '', txt)
	if (opts.preferSummary && (opts.entryIsForeign || (properties.name && properties.name.length > 0))) {
		// In feeds (but not for local notes), avoid showing giant walls of text or media
		txt = truncate(textContent, 96, { byWords: true, ellipsis: '…', reserveLastWord: true })
		media.photo = media.photo.slice(0, 2)
		media.video = media.video.slice(0, 1)
		media.audio = media.audio.slice(0, 2)
	}
	return Object.assign({ textContent: txt, isCrapName }, media)
}

export function findMentionedLinks (obj) {
	const fromCtxs = concat(
		get(obj, 'properties.in-reply-to', []),
		get(obj, 'properties.like-of', []),
		get(obj, 'properties.repost-of', []),
		get(obj, 'properties.quotation-of', [])
	).map(ctx => isObject(ctx) ? get(ctx, 'properties.url.0') : ctx)
	let fromContent = []
	try {
		const $ = cheerio.load(this.getContent(obj.properties, true, false))
		fromContent = $('a, link').toArray().map(el => el.attribs['href'])
	} catch (err) {
		log('HTML content parse error: %O', err)
	}
	return concat(fromCtxs, fromContent).filter(isString)
}

export function getHtmlLinksByRel (content) {
	const $ = cheerio.load(content)
	return $('link[rel], a[rel]').toArray()
		.filter(el => includes(el.attribs['rel'].split(/\s+/), 'webmention') && isString(el.attribs['href']))
		.map(el => el.attribs['href'])
}

export function isActuallyTheSameDamnThing(name, content) {
	const process = x => entities.decodeHTML(x).replace(/\s+/g, '').replace(/<[^>]+>/g, '')
	const n = process(name)
	const c = process(content)
	return n.length > 2 && c.length > 2 && n.includes(c)
}

export function containerStyle (media) {
	let result = ''
	if (!media) {
		return result
	}
	const color = head(sortBy(media.palette, 'population'))
	const preview = media.tiny_preview
	if (color || preview) {
		result += 'background:'
		if (color) {
			result += color.color
		}
		if (preview) {
			result += ` url('${preview}')`
		}
		result += ';'
	}
	if (media.width && media.height) {
		result += `padding-bottom:${(media.height / media.width * 100).toPrecision(4)}%`
	}
	return result
}

export function galleryRows (entries) {
	const result = []
	let cur = []
	let cur_slots = 0
	for (const entry of entries) {
		cur.push(entry)
		const media = get(entry, 'properties.photo[0]', get(entry, 'properties.video[0]', {}))
		cur_slots += media.width > media.height ? 2 : 1
		if (cur_slots >= 4) {
			result.push(cur)
			cur = []
			cur_slots = 0
		}
	}
	if (cur.length !== 0) {
		result.push(cur)
	}
	return result
}
