package com.android.purebilibili.core.network

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import retrofit2.http.Body
import retrofit2.http.GET
import retrofit2.http.Query
import retrofit2.http.QueryMap

class DynamicApiContractTest {

    @Test
    fun likeDynamic_usesQueryCsrfAndJsonBody() {
        val method = DynamicApi::class.java.methods.first { it.name == "likeDynamic" }

        val firstParamAnnotations = method.parameterAnnotations[0].toList()
        val secondParamAnnotations = method.parameterAnnotations[1].toList()
        val thirdParamAnnotations = method.parameterAnnotations[2].toList()

        val query = firstParamAnnotations.filterIsInstance<Query>().firstOrNull()
        assertEquals("csrf", query?.value)

        val csrfTokenQuery = secondParamAnnotations.filterIsInstance<Query>().firstOrNull()
        assertEquals("csrf_token", csrfTokenQuery?.value)

        assertTrue(thirdParamAnnotations.any { it is Body })
        assertEquals(DynamicThumbRequest::class.java, method.parameterTypes[2])
    }

    @Test
    fun dynamicThumbRequest_defaultsMatchDesktopWebClient() {
        val request = DynamicThumbRequest(dyn_id_str = "123", up = 1)

        assertEquals("333.1369.0.0", request.spmid)
        assertEquals("333.999.0.0", request.from_spmid)
    }

    @Test
    fun getDynamicDetail_usesDesktopDetailEndpointAndIdQuery() {
        val method = DynamicApi::class.java.methods.first { it.name == "getDynamicDetail" }
        val get = method.getAnnotation(GET::class.java)
        assertEquals("x/polymer/web-dynamic/desktop/v1/detail", get?.value)

        val firstParamAnnotations = method.parameterAnnotations[0].toList()
        val idQuery = firstParamAnnotations.filterIsInstance<Query>().firstOrNull()
        assertEquals("id", idQuery?.value)
    }

    @Test
    fun getDynamicDetailFallback_usesLegacyDetailEndpointAndIdQuery() {
        val method = DynamicApi::class.java.methods.first { it.name == "getDynamicDetailFallback" }
        val get = method.getAnnotation(GET::class.java)
        assertEquals("x/polymer/web-dynamic/v1/detail", get?.value)

        val firstParamAnnotations = method.parameterAnnotations[0].toList()
        val idQuery = firstParamAnnotations.filterIsInstance<Query>().firstOrNull()
        assertEquals("id", idQuery?.value)
    }

    @Test
    fun getOpusDetail_usesDocumentedOpusDetailEndpointAndIdQuery() {
        val method = DynamicApi::class.java.methods.first { it.name == "getOpusDetail" }
        val get = method.getAnnotation(GET::class.java)
        assertEquals("x/polymer/web-dynamic/v1/opus/detail", get?.value)

        val firstParamAnnotations = method.parameterAnnotations[0].toList()
        val idQuery = firstParamAnnotations.filterIsInstance<Query>().firstOrNull()
        assertEquals("id", idQuery?.value)
    }

    @Test
    fun getSpaceArticleList_usesDocumentedOpusSpaceFeedEndpointAndQueryMap() {
        val method = SpaceApi::class.java.methods.first { it.name == "getSpaceArticleList" }
        val get = method.getAnnotation(GET::class.java)
        assertEquals("x/polymer/web-dynamic/v1/opus/feed/space", get?.value)

        val firstParamAnnotations = method.parameterAnnotations[0].toList()
        assertTrue(firstParamAnnotations.any { it is QueryMap })
    }

    @Test
    fun getSpaceDynamic_requestsFeatureFlagsForOpusTextAndCommentCounts() {
        val method = SpaceApi::class.java.methods.first { it.name == "getSpaceDynamic" }
        val get = method.getAnnotation(GET::class.java)
        assertEquals("x/polymer/web-dynamic/v1/feed/space", get?.value)

        val queryNames = method.parameterAnnotations
            .mapNotNull { annotations ->
                annotations.filterIsInstance<Query>().firstOrNull()?.value
            }

        assertTrue("features" in queryNames)
        assertTrue(SPACE_DYNAMIC_FEATURES.contains("itemOpusStyle"))
        assertTrue(SPACE_DYNAMIC_FEATURES.contains("opusBigCover"))
        assertTrue(SPACE_DYNAMIC_FEATURES.contains("commentsNewVersion"))
    }

    @Test
    fun getUserDynamicFeed_usesDynamicFeedAllEndpointAndQueryMap() {
        val method = DynamicApi::class.java.methods.first { it.name == "getUserDynamicFeed" }
        val get = method.getAnnotation(GET::class.java)
        assertEquals("x/polymer/web-dynamic/v1/feed/all", get?.value)

        val firstParamAnnotations = method.parameterAnnotations[0].toList()
        assertTrue(firstParamAnnotations.any { it is QueryMap })
    }

    @Test
    fun getPbpData_usesBilivideoPbpEndpoint() {
        val method = BilibiliApi::class.java.methods.first { it.name == "getPbpData" }
        val get = method.getAnnotation(GET::class.java)

        assertEquals("https://bvc.bilivideo.com/pbp/data", get?.value)
    }
}
