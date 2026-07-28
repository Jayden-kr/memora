package com.henry.memora

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/**
 * 앱 내 언어 설정(Flutter `LocaleService`)의 네이티브 미러.
 *
 * 알림·채널·PDF 같은 네이티브 문자열은 시스템 언어를 따라가면 안 된다 — 사용자가 앱에서
 * 고른 언어를 따라야 한다. Flutter가 언어를 정하거나 바꿀 때마다 MainActivity가 [save]로
 * 여기에 기록하고, 네이티브는 [wrap]으로 그 언어가 강제된 Context를 얻어 문자열을 읽는다.
 *
 * **전용 prefs 파일을 쓰는 이유**: `push_notif_prefs`는 `:push` 프로세스와 공유되는데,
 * SharedPreferences는 프로세스별로 전체 맵을 캐시했다가 commit 시 통째로 다시 쓴다.
 * 메인 프로세스가 거기 쓰면 :push가 기록한 스케줄을 되돌릴 수 있다(MainActivity의 stopService
 * 주석 참고). 이 파일은 **메인 프로세스만 write**하므로 그 위험이 없다.
 *
 * `:push`는 이 파일 대신 자기 소유 `lang` 키를 계속 쓴다(프로세스 캐시 불일치 회피).
 * 언어가 바뀌면 메인이 [ACTION_SET_LANG] 인텐트로 알려주고 :push가 스스로 갱신한다.
 */
object AppLang {
    private const val PREFS = "app_lang_prefs"
    private const val KEY = "lang"

    /** 실행 중인 서비스에 언어 변경을 통지하는 액션 — 받은 쪽은 알림을 즉시 다시 만든다. */
    const val ACTION_SET_LANG = "com.henry.memora.SET_LANG"
    const val EXTRA_LANG = "lang"

    /** 현재 앱 언어. 저장값이 없으면 시스템 언어로 추정한다. */
    fun current(context: Context): String = normalize(
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
    )

    /**
     * 메인 프로세스 전용. Flutter가 언어를 정할 때마다 호출된다.
     * [code]가 null이면 '시스템 언어 따라가기' — 저장값을 지워서 읽을 때마다 시스템을
     * 다시 보게 한다(해석된 값을 박아두면 나중에 폰 언어를 바꿔도 안 따라감).
     */
    fun save(context: Context, code: String?) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (code.isNullOrEmpty()) {
            prefs.edit().remove(KEY).commit()
        } else {
            prefs.edit().putString(KEY, normalize(code)).commit()
        }
    }

    /**
     * 지원 언어(ko/en)로 정규화. 미지원이면 시스템 언어, 그것도 아니면 영어.
     * 영어 폴백은 Flutter `supportedLocales`의 첫 항목(en)과 같은 규칙이다 — 두 계층이
     * 다른 언어로 갈리지 않도록 맞춘 것.
     */
    fun normalize(code: String?): String {
        if (code == "ko" || code == "en") return code
        return if (Locale.getDefault().language == "ko") "ko" else "en"
    }

    /** [code] 언어가 강제된 Context. 문자열 리소스 조회는 반드시 이걸 거친다. */
    fun wrap(context: Context, code: String = current(context)): Context {
        val config = Configuration(context.resources.configuration)
        config.setLocale(Locale(code))
        return context.createConfigurationContext(config)
    }
}
