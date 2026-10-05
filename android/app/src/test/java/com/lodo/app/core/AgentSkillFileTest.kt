package com.lodo.app.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AgentSkillFileTest {
    @Test fun parsesAndRoundTrips() {
        val text = "﻿\n---\nname: \"写周报\"\ndescription: 按公司格式写周报\ngroup: 我的\nversion: 2\n---\n先列完成的事\n再列下周计划\n"
        val (file, err) = AgentSkillFile.parse(text)
        assertNull(err)
        assertEquals("写周报", file!!.name)
        assertEquals("我的", file.group)
        assertEquals(2, file.version)
        assertEquals("先列完成的事\n再列下周计划", file.body)
        assertEquals(file, AgentSkillFile.parse(file.render()).first)
    }

    @Test fun reportsErrors() {
        assertEquals(AgentSkillFile.ParseError.MISSING_FRONTMATTER, AgentSkillFile.parse("name: x").second)
        assertEquals(AgentSkillFile.ParseError.MISSING_DESCRIPTION, AgentSkillFile.parse("---\nname: x\n---\nbody").second)
        assertEquals(AgentSkillFile.ParseError.EMPTY_BODY, AgentSkillFile.parse("---\nname: x\ndescription: y\n---\n  ").second)
        assertEquals(AgentSkillFile.ParseError.BODY_TOO_LONG,
            AgentSkillFile.parse("---\nname: x\ndescription: y\n---\n" + "字".repeat(6001)).second)
    }

    @Test fun slugAndCatalog() {
        assertEquals("写周报-v2", AgentSkillFile.slug("写周报 v2!"))
        assertEquals("skill", AgentSkillFile.slug("!!!"))
        assertNull(AgentSkillFile.catalogBlock(emptyList()))
        val block = AgentSkillFile.catalogBlock(listOf(AgentSkillFile("写周报", "按公司格式写周报", body = "b")))!!
        assertEquals(true, block.endsWith("- 写周报:按公司格式写周报"))
    }
}
